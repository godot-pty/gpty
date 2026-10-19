//! Godot bridge for the media backend: one `GptyMedia` node per media pane.
//!
//! The class is a thin JSON/packed-array edge over [`gpty_media`]. All decode
//! work runs on the session's own OS thread; every method here returns
//! promptly and never blocks on a packet. Input is a JSON string because the
//! Godot export attribute only marshals `GString`/`bool`/`i64` inputs reliably.
//!
//! `poll_video` and `poll_audio` return one item per call (an empty
//! `Dictionary` when the queue is empty). The pane polls until empty, which
//! keeps the FFI surface small and the packed arrays contiguous.

use std::panic::{AssertUnwindSafe, catch_unwind};

use godot::builtin::{Dictionary, PackedByteArray, PackedFloat32Array};
use godot::prelude::*;
use gpty_media::{
    AudioInfo, MediaError, MediaInfo, MediaSession, OpenConfig, StreamInfo, VideoInfo,
};
use serde_json::{Value, json};

#[derive(GodotClass)]
#[class(base = Node)]
struct GptyMedia {
    session: Option<MediaSession>,
    base: Base<Node>,
}

#[godot_api]
impl INode for GptyMedia {
    fn init(base: Base<Node>) -> Self {
        Self {
            session: None,
            base,
        }
    }
}

impl Drop for GptyMedia {
    fn drop(&mut self) {
        self.session = None;
    }
}

#[godot_api]
impl GptyMedia {
    /// Open a media file, replacing any session this node already owns.
    ///
    /// Input: `{"path":"/abs/file", "sample_rate":48000, "channels":2,
    /// "max_width":0, "max_height":0}`. Output: `{"ok":true,"state":"opening"}`
    /// or `{"ok":false,"error":{"code":"...","message":"..."}}`. The path is
    /// validated synchronously; probing/decoding runs on the session thread,
    /// and `status()` reports `Playing` with the stream info (or `Failed`).
    #[func]
    fn open(&mut self, config_json: GString) -> GString {
        guarded(|| {
            let value: Value = match serde_json::from_str(&config_json.to_string()) {
                Ok(value) => value,
                Err(error) => return error_json("bad_request", &format!("invalid JSON: {error}")),
            };
            let config = match open_config(&value) {
                Ok(config) => config,
                Err(message) => return error_json("bad_request", &message),
            };
            // Replace before opening: a pane changing files must release the
            // previous decoder even if the new file is refused.
            self.session = None;
            match MediaSession::start(config) {
                Ok(session) => {
                    // The worker probes on its own thread; `status()` reports
                    // Playing with `info`, or Failed with the reason. Blocking
                    // here would let a crafted file hold the Godot thread for
                    // the whole open budget.
                    self.session = Some(session);
                    GString::from(r#"{"ok":true,"state":"opening"}"#)
                }
                Err(error) => error_json(error.code().as_str(), error.message()),
            }
        })
    }

    /// Poll one decoded video frame.
    ///
    /// Returns `{}` when the queue is empty, else
    /// `{width, height, pts_us, keyframe, data}` with `data` a packed RGBA8
    /// array of `width * height * 4` bytes.
    #[func]
    fn poll_video(&mut self) -> Dictionary<Variant, Variant> {
        let Some(session) = self.session.as_ref() else {
            return Dictionary::new();
        };
        let Some(frame) = session.poll_video(1).into_iter().next() else {
            return Dictionary::new();
        };
        let mut dict = Dictionary::<Variant, Variant>::new();
        dict.set("width", &Variant::from(frame.width as i64));
        dict.set("height", &Variant::from(frame.height as i64));
        dict.set("pts_us", &Variant::from(frame.pts_us as i64));
        dict.set("keyframe", &Variant::from(frame.keyframe));
        dict.set(
            "data",
            &Variant::from(PackedByteArray::from(frame.data.as_slice())),
        );
        dict
    }

    /// Poll one decoded audio chunk.
    ///
    /// Returns `{}` when the queue is empty, else
    /// `{sample_rate, channels, pts_us, data}` with `data` interleaved f32.
    #[func]
    fn poll_audio(&mut self) -> Dictionary<Variant, Variant> {
        let Some(session) = self.session.as_ref() else {
            return Dictionary::new();
        };
        let Some(chunk) = session.poll_audio(1).into_iter().next() else {
            return Dictionary::new();
        };
        let mut dict = Dictionary::<Variant, Variant>::new();
        dict.set("sample_rate", &Variant::from(chunk.sample_rate as i64));
        dict.set("channels", &Variant::from(chunk.channels as i64));
        dict.set("pts_us", &Variant::from(chunk.pts_us as i64));
        dict.set(
            "data",
            &Variant::from(PackedFloat32Array::from(chunk.data.as_slice())),
        );
        dict
    }

    /// Seek to `position_us`. Output: `{"ok":true}` or an error envelope.
    #[func]
    fn seek(&mut self, position_us: i64) -> GString {
        guarded(|| {
            let Some(session) = self.session.as_ref() else {
                return error_json("closed", "no media session is open");
            };
            match session.seek(position_us.max(0) as u64) {
                Ok(()) => GString::from(r#"{"ok":true}"#),
                Err(error) => error_json(error.code().as_str(), error.message()),
            }
        })
    }

    /// Session state, position and stream information as JSON.
    #[func]
    fn status(&mut self) -> GString {
        guarded(|| {
            let Some(session) = self.session.as_ref() else {
                return GString::from(
                    r#"{"ok":true,"state":"closed","position_us":0,"duration_us":null,"info":null,"error":null}"#,
                );
            };
            let status = session.status();
            let answer = json!({
                "ok": true,
                "state": status.state.as_str(),
                "position_us": status.position_us,
                "duration_us": status.duration_us,
                "info": status.info.as_ref().map(info_json),
                "error": status.error.as_ref().map(error_value),
            });
            GString::from(answer.to_string().as_str())
        })
    }

    /// Stop the decoder and release the file. Idempotent.
    #[func]
    fn close(&mut self) {
        self.session = None;
    }
}

fn guarded(f: impl FnOnce() -> GString) -> GString {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(answer) => answer,
        Err(_) => {
            // A panic must not unwind into Godot. The session (if any) is
            // dropped by the next `open`/`close`; report a stable code.
            godot_error!("GptyMedia: panic caught at the FFI boundary");
            error_json("panic", "media bridge panicked")
        }
    }
}

fn open_config(value: &Value) -> Result<OpenConfig, String> {
    let object = value
        .as_object()
        .ok_or_else(|| "configuration must be a JSON object".to_string())?;
    let path = object
        .get("path")
        .and_then(Value::as_str)
        .ok_or_else(|| "configuration needs a \"path\" string".to_string())?;
    let mut config = OpenConfig::new(path);
    if let Some(rate) = object.get("sample_rate") {
        config.sample_rate = number(rate, "sample_rate")?;
    }
    if let Some(channels) = object.get("channels") {
        config.channels = u16::try_from(number(channels, "channels")?)
            .map_err(|_| "\"channels\" is too large".to_string())?;
    }
    if let Some(width) = object.get("max_width") {
        config.max_width = number(width, "max_width")?;
    }
    if let Some(height) = object.get("max_height") {
        config.max_height = number(height, "max_height")?;
    }
    Ok(config)
}

fn number(value: &Value, field: &str) -> Result<u32, String> {
    let raw = value
        .as_u64()
        .ok_or_else(|| format!("\"{field}\" must be a non-negative integer"))?;
    u32::try_from(raw).map_err(|_| format!("\"{field}\" is too large"))
}

fn error_envelope(code: &str, message: &str) -> String {
    json!({"ok": false, "error": {"code": code, "message": message}}).to_string()
}

fn error_json(code: &str, message: &str) -> GString {
    GString::from(error_envelope(code, message).as_str())
}

fn error_value(error: &MediaError) -> Value {
    json!({"code": error.code().as_str(), "message": error.message()})
}

fn info_json(info: &MediaInfo) -> Value {
    json!({
        "container": info.container,
        "duration_us": info.duration_us,
        "video": info.video.as_ref().map(video_json),
        "audio": info.audio.as_ref().map(audio_json),
        "streams": info.streams.iter().map(stream_json).collect::<Vec<_>>(),
    })
}

fn video_json(video: &VideoInfo) -> Value {
    json!({
        "codec": video.codec,
        "width": video.width,
        "height": video.height,
        "frame_rate_num": video.frame_rate_num,
        "frame_rate_den": video.frame_rate_den,
    })
}

fn audio_json(audio: &AudioInfo) -> Value {
    json!({
        "codec": audio.codec,
        "sample_rate": audio.sample_rate,
        "channels": audio.channels,
    })
}

fn stream_json(stream: &StreamInfo) -> Value {
    json!({
        "index": stream.index,
        "kind": stream.kind.as_str(),
        "codec": stream.codec,
        "width": stream.width,
        "height": stream.height,
        "sample_rate": stream.sample_rate,
        "channels": stream.channels,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use gpty_media::SessionState;

    #[test]
    fn open_config_reads_defaults_and_overrides() {
        let config = open_config(&json!({"path": "/tmp/a.mp4"})).unwrap();
        assert_eq!(config.sample_rate, 48_000);
        assert_eq!(config.channels, 2);
        assert_eq!(config.max_width, 0);

        let config = open_config(&json!({
            "path": "/tmp/a.mp4",
            "sample_rate": 44_100,
            "channels": 1,
            "max_width": 640,
            "max_height": 360,
        }))
        .unwrap();
        assert_eq!(config.sample_rate, 44_100);
        assert_eq!(config.channels, 1);
        assert_eq!(config.max_width, 640);
        assert_eq!(config.max_height, 360);
    }

    #[test]
    fn open_config_rejects_bad_shapes() {
        assert!(open_config(&json!({})).is_err());
        assert!(open_config(&json!({"path": 3})).is_err());
        assert!(open_config(&json!({"path": "/a", "channels": -1})).is_err());
        assert!(open_config(&json!({"path": "/a", "sample_rate": 1.5})).is_err());
        assert!(open_config(&json!({"path": "/a", "channels": 4_000_000_000u64})).is_err());
    }

    #[test]
    fn error_envelope_has_a_stable_code() {
        let value: Value = serde_json::from_str(&error_envelope("bad_path", "nope")).unwrap();
        assert_eq!(value["ok"], false);
        assert_eq!(value["error"]["code"], "bad_path");
    }

    #[test]
    fn session_state_names_are_stable() {
        assert_eq!(SessionState::Playing.as_str(), "playing");
        assert_eq!(SessionState::Finished.as_str(), "finished");
    }
}
