//! Container inspection: the single place a path becomes streams and codecs.
//!
//! Both [`probe`] and [`crate::MediaSession`] open through [`open_input`], so
//! the path gate, demuxer allowlist, stream caps and codec allowlist cannot
//! drift between "just looking" and "decoding".

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use ffmpeg_the_third as ffmpeg;

use crate::error::MediaError;
use crate::{
    ALLOWED_DEMUXERS, MAX_CHANNELS, MAX_SAMPLE_RATE, MAX_STREAMS, MAX_VIDEO_DIMENSION,
    OPEN_TIMEOUT_MS, audio_codec_allowed, ensure_ffmpeg_init, timestamp_to_us, validate_path,
    video_codec_allowed,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StreamKind {
    Video,
    Audio,
}

impl StreamKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Video => "video",
            Self::Audio => "audio",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StreamInfo {
    pub index: usize,
    pub kind: StreamKind,
    pub codec: String,
    pub width: u32,
    pub height: u32,
    pub sample_rate: u32,
    pub channels: u16,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VideoInfo {
    pub codec: String,
    pub width: u32,
    pub height: u32,
    pub frame_rate_num: u32,
    pub frame_rate_den: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AudioInfo {
    pub codec: String,
    pub sample_rate: u32,
    pub channels: u16,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MediaInfo {
    pub container: String,
    pub duration_us: Option<u64>,
    pub streams: Vec<StreamInfo>,
    pub video: Option<VideoInfo>,
    pub audio: Option<AudioInfo>,
}

/// The input context plus the first decodable stream of each kind.
///
/// The decoder contexts are created during inspection so a caller cannot
/// select a stream and then forget to build its decoder.
pub(crate) struct OpenedInput {
    pub input: ffmpeg::format::context::Input,
    pub info: MediaInfo,
    pub video: Option<VideoStream>,
    pub audio: Option<AudioStream>,
}

pub(crate) struct VideoStream {
    pub index: usize,
    pub time_base: ffmpeg::Rational,
    pub decoder: ffmpeg::codec::decoder::Video,
}

pub(crate) struct AudioStream {
    pub index: usize,
    pub time_base: ffmpeg::Rational,
    pub decoder: ffmpeg::codec::decoder::Audio,
}

/// Open and inspect `path`, without starting a decode worker.
pub fn probe(path: &str) -> Result<MediaInfo, MediaError> {
    let stop = Arc::new(AtomicBool::new(false));
    let opened = open_input(path, stop)?;
    Ok(opened.info)
}

/// Open `path` with a wall-clock budget and validate everything this backend
/// is allowed to read. `stop` lets a session close interrupt a blocked open.
pub(crate) fn open_input(path: &str, stop: Arc<AtomicBool>) -> Result<OpenedInput, MediaError> {
    ensure_ffmpeg_init()?;
    let path = validate_path(path)?;

    // The deadline applies to open/probe only. The callback lives in the
    // input context for the session's lifetime, so keeping it armed would
    // abort a long playback; it is cleared as soon as the file is open.
    let deadline = Arc::new(Mutex::new(Some(
        Instant::now() + Duration::from_millis(OPEN_TIMEOUT_MS),
    )));
    let input = {
        let stop_cb = stop.clone();
        let deadline_cb = deadline.clone();
        ffmpeg::format::input_with_interrupt(&path, move || {
            if stop_cb.load(Ordering::Relaxed) {
                return true;
            }
            deadline_cb
                .lock()
                .ok()
                .and_then(|d| *d)
                .is_some_and(|d| Instant::now() >= d)
        })
    }
    .map_err(|e| MediaError::open(format!("cannot open media: {e}")))?;
    *deadline
        .lock()
        .map_err(|_| MediaError::open("media open lock poisoned"))? = None;

    // FFmpeg reports a demuxer's whole alias list (`mov,mp4,m4a,3gp,3g2,mj2`),
    // so the allowlist matches any one alias and reports the matched name.
    let raw_container = input.format().name();
    let container = raw_container
        .split(',')
        .map(str::trim)
        .find(|name| ALLOWED_DEMUXERS.contains(name))
        .map(str::to_string)
        .ok_or_else(|| {
            MediaError::unsupported_container(format!(
                "container {raw_container:?} is not in the media allowlist"
            ))
        })?;

    let duration_us = {
        let duration = input.duration();
        (duration > 0).then_some(duration as u64)
    };

    let mut info = MediaInfo {
        container,
        duration_us,
        streams: Vec::new(),
        video: None,
        audio: None,
    };
    let mut video = None;
    let mut audio = None;

    for (stream_position, stream) in input.streams().enumerate() {
        if stream_position >= MAX_STREAMS {
            break;
        }
        let params = stream.parameters();
        let kind = match params.medium() {
            ffmpeg::media::Type::Video => StreamKind::Video,
            ffmpeg::media::Type::Audio => StreamKind::Audio,
            _ => continue,
        };
        let codec_id = params.id();
        if ffmpeg::codec::decoder::find(codec_id).is_none() {
            log::warn!(
                "media: stream {} uses {:?} with no decoder in this build",
                stream.index(),
                codec_id
            );
            continue;
        }
        // The *implementation* name can be `libdav1d` where the codec is
        // `av1`; the allowlist and the reported stream use the codec id's
        // stable name, while `find` above proves a decoder exists.
        let codec_name = codec_id.name().to_string();
        let width = params.width();
        let height = params.height();
        let sample_rate = params.sample_rate();
        let channels = params.ch_layout().channels();

        // Cover art in an audio file is a video stream by disposition, not a
        // video track: it must not become the selected video or make an MP3
        // fail because its embedded JPEG has no allowed decoder.
        let attached_pic = stream
            .disposition()
            .contains(ffmpeg::format::stream::Disposition::ATTACHED_PIC);
        let candidate = match kind {
            StreamKind::Video => video.is_none() && !attached_pic,
            StreamKind::Audio => audio.is_none(),
        };

        info.streams.push(StreamInfo {
            index: stream.index(),
            kind,
            codec: codec_name.clone(),
            width,
            height,
            sample_rate,
            channels: channels.min(u16::MAX as u32) as u16,
        });
        if !candidate {
            continue;
        }

        // Only the stream that would actually be played is held to the
        // allowlist; a second, unsupported track does not make the file
        // unplayable.
        let allowed = match kind {
            StreamKind::Video => video_codec_allowed(&codec_name),
            StreamKind::Audio => audio_codec_allowed(&codec_name),
        };
        if !allowed {
            return Err(MediaError::unsupported_codec(format!(
                "codec {codec_name:?} is not in the media allowlist"
            )));
        }

        if kind == StreamKind::Video
            && (width == 0
                || height == 0
                || width > MAX_VIDEO_DIMENSION
                || height > MAX_VIDEO_DIMENSION)
        {
            return Err(MediaError::too_large(format!(
                "video stream {} is {width}x{height}; the cap is {MAX_VIDEO_DIMENSION} per side",
                stream.index()
            )));
        }
        if kind == StreamKind::Audio
            && (channels == 0
                || channels > MAX_CHANNELS as u32
                || sample_rate == 0
                || sample_rate > MAX_SAMPLE_RATE)
        {
            return Err(MediaError::too_large(format!(
                "audio stream {} is {sample_rate} Hz × {channels} channels",
                stream.index()
            )));
        }

        match kind {
            StreamKind::Video if video.is_none() => {
                let context = ffmpeg::codec::context::Context::from_parameters(params)
                    .map_err(|e| MediaError::open(format!("cannot read video parameters: {e}")))?;
                let decoder = context
                    .decoder()
                    .video()
                    .map_err(|e| MediaError::open(format!("cannot open video decoder: {e}")))?;
                let rate = stream.avg_frame_rate();
                info.video = Some(VideoInfo {
                    codec: codec_name,
                    width,
                    height,
                    frame_rate_num: rate.numerator().max(0) as u32,
                    frame_rate_den: rate.denominator().max(1) as u32,
                });
                video = Some(VideoStream {
                    index: stream.index(),
                    time_base: stream.time_base(),
                    decoder,
                });
            }
            StreamKind::Audio if audio.is_none() => {
                let context = ffmpeg::codec::context::Context::from_parameters(params)
                    .map_err(|e| MediaError::open(format!("cannot read audio parameters: {e}")))?;
                let decoder = context
                    .decoder()
                    .audio()
                    .map_err(|e| MediaError::open(format!("cannot open audio decoder: {e}")))?;
                info.audio = Some(AudioInfo {
                    codec: codec_name,
                    sample_rate,
                    channels: channels as u16,
                });
                audio = Some(AudioStream {
                    index: stream.index(),
                    time_base: stream.time_base(),
                    decoder,
                });
            }
            _ => {}
        }
    }

    if video.is_none() && audio.is_none() {
        return Err(MediaError::unsupported_codec(
            "no decodable audio or video stream",
        ));
    }

    log::debug!(
        "media: opened {} ({}), streams: {}",
        path.display(),
        info.container,
        info.streams.len()
    );
    Ok(OpenedInput {
        input,
        info,
        video,
        audio,
    })
}

/// The packet/frame timestamp in microseconds.
pub(crate) fn frame_time_us(ts: i64, time_base: ffmpeg::Rational) -> u64 {
    timestamp_to_us(ts, time_base.numerator(), time_base.denominator())
}
