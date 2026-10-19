use std::path::PathBuf;
use std::thread;
use std::time::{Duration, Instant};

use gpty_media::{
    AudioChunk, MediaError, MediaErrorCode, MediaSession, OpenConfig, SessionState, VideoFrame,
    probe,
};

fn open_err(config: OpenConfig) -> MediaError {
    match MediaSession::open(config) {
        Ok(_) => panic!("expected the session to be refused"),
        Err(error) => error,
    }
}

fn fixture(name: &str) -> String {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name)
        .to_string_lossy()
        .into_owned()
}

fn wait_video(session: &MediaSession, want: usize) -> Vec<VideoFrame> {
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut frames = Vec::new();
    while frames.len() < want {
        frames.extend(session.poll_video(want - frames.len()));
        if frames.len() >= want {
            break;
        }
        let status = session.status();
        match status.state {
            SessionState::Finished => break,
            SessionState::Failed => {
                panic!("media session failed: {:?}", status.error);
            }
            _ => {}
        }
        assert!(
            Instant::now() < deadline,
            "timed out waiting for video frames; state {:?}",
            status.state
        );
        thread::sleep(Duration::from_millis(10));
    }
    frames
}

fn wait_audio(session: &MediaSession, want_chunks: usize) -> Vec<AudioChunk> {
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut chunks = Vec::new();
    while chunks.len() < want_chunks {
        chunks.extend(session.poll_audio(want_chunks - chunks.len()));
        if chunks.len() >= want_chunks {
            break;
        }
        let status = session.status();
        match status.state {
            SessionState::Finished => break,
            SessionState::Failed => {
                panic!("media session failed: {:?}", status.error);
            }
            _ => {}
        }
        assert!(
            Instant::now() < deadline,
            "timed out waiting for audio chunks; state {:?}",
            status.state
        );
        thread::sleep(Duration::from_millis(10));
    }
    chunks
}

fn collect_audio_to_end(session: &MediaSession) -> Vec<AudioChunk> {
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut chunks = Vec::new();
    loop {
        chunks.extend(session.poll_audio(64));
        let status = session.status();
        if status.state == SessionState::Failed {
            panic!("media session failed: {:?}", status.error);
        }
        if status.state == SessionState::Finished && chunks.is_empty() {
            return Vec::new();
        }
        if status.state == SessionState::Finished {
            // One more drain so the final queued chunk is included.
            chunks.extend(session.poll_audio(64));
            return chunks;
        }
        assert!(Instant::now() < deadline, "timed out collecting audio");
        thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn probe_reports_each_supported_container_and_codec() {
    let cases = [
        ("h264.mp4", "mov", Some("h264"), None),
        ("av_h264_aac.mp4", "mov", Some("h264"), Some("aac")),
        ("hevc.mp4", "mov", Some("hevc"), None),
        ("vp9.webm", "matroska", Some("vp9"), None),
        ("av1.mkv", "matroska", Some("av1"), None),
        ("theora.ogv", "ogg", Some("theora"), None),
        ("vorbis.ogg", "ogg", None, Some("vorbis")),
        ("opus.ogg", "ogg", None, Some("opus")),
        ("flac.flac", "flac", None, Some("flac")),
        ("mp3.mp3", "mp3", None, Some("mp3")),
        ("aac.m4a", "mov", None, Some("aac")),
        ("wav.wav", "wav", None, Some("pcm_s16le")),
    ];
    for (file, container, video_codec, audio_codec) in cases {
        let info = probe(&fixture(file)).unwrap_or_else(|e| panic!("{file}: {e}"));
        assert_eq!(info.container, container, "{file}");
        assert_eq!(
            info.video.as_ref().map(|v| v.codec.as_str()),
            video_codec,
            "{file}"
        );
        assert_eq!(
            info.audio.as_ref().map(|a| a.codec.as_str()),
            audio_codec,
            "{file}"
        );
        if let Some(video) = info.video {
            assert_eq!((video.width, video.height), (64, 48), "{file}");
        }
        if let Some(audio) = info.audio {
            assert_eq!(audio.channels, 2, "{file}");
            assert_eq!(audio.sample_rate, 48_000, "{file}");
        }
        assert!(info.duration_us.is_some(), "{file} has no duration");
    }
}

#[test]
fn video_decodes_to_packed_rgba() {
    let session = MediaSession::open(OpenConfig::new(fixture("h264.mp4"))).unwrap();
    let frames = wait_video(&session, 1);
    assert!(!frames.is_empty(), "no frame decoded");
    let frame = &frames[0];
    assert_eq!((frame.width, frame.height), (64, 48));
    assert_eq!(frame.data.len(), 64 * 48 * 4);
    assert!(
        frame.data.chunks_exact(4).all(|px| px[3] == 255),
        "RGBA alpha was not opaque"
    );
    assert!(session.status().info.unwrap().video.is_some());
}

#[test]
fn video_downscales_to_the_requested_box() {
    let mut config = OpenConfig::new(fixture("h264.mp4"));
    config.max_width = 32;
    config.max_height = 24;
    let session = MediaSession::open(config).unwrap();
    let frames = wait_video(&session, 1);
    assert_eq!((frames[0].width, frames[0].height), (32, 24));
    assert_eq!(frames[0].data.len(), 32 * 24 * 4);
}

#[test]
fn audio_resamples_to_the_requested_rate_and_channels() {
    let mut config = OpenConfig::new(fixture("opus.ogg"));
    config.sample_rate = 44_100;
    config.channels = 2;
    let session = MediaSession::open(config).unwrap();
    let chunks = collect_audio_to_end(&session);
    assert!(!chunks.is_empty(), "no audio decoded");
    let mut frames = 0usize;
    for chunk in &chunks {
        assert_eq!(chunk.sample_rate, 44_100);
        assert_eq!(chunk.channels, 2);
        assert!(!chunk.data.is_empty());
        assert_eq!(chunk.data.len() % 2, 0);
        frames += chunk.frames();
    }
    // 0.25 s at 44.1 kHz, with Opus pre-skip and AAC-style encoder padding.
    assert!(
        (8_000..=13_000).contains(&frames),
        "decoded {frames} frames, expected about 11 025"
    );
}

#[test]
fn audio_resamples_to_mono_when_requested() {
    let mut config = OpenConfig::new(fixture("flac.flac"));
    config.sample_rate = 22_050;
    config.channels = 1;
    let session = MediaSession::open(config).unwrap();
    let chunks = collect_audio_to_end(&session);
    assert!(!chunks.is_empty());
    for chunk in &chunks {
        assert_eq!(chunk.sample_rate, 22_050);
        assert_eq!(chunk.channels, 1);
        assert!(chunk.frames() > 0);
    }
}

#[test]
fn an_av_file_produces_both_streams() {
    let session = MediaSession::open(OpenConfig::new(fixture("av_h264_aac.mp4"))).unwrap();
    let frames = wait_video(&session, 1);
    let chunks = wait_audio(&session, 1);
    assert!(!frames.is_empty());
    assert!(!chunks.is_empty());
    let info = session.status().info.unwrap();
    assert!(info.video.is_some());
    assert!(info.audio.is_some());
}

#[test]
fn seek_lands_at_or_after_the_target() {
    let session = MediaSession::open(OpenConfig::new(fixture("long_h264.mp4"))).unwrap();
    let first = wait_video(&session, 1);
    assert_eq!(first[0].pts_us, 0);

    session.seek(1_500_000).unwrap();
    let after = wait_video(&session, 1);
    assert!(
        after.first().is_some_and(|frame| frame.pts_us >= 1_400_000),
        "seek returned {:?}",
        after.first().map(|frame| frame.pts_us)
    );

    session.seek(0).unwrap();
    let back = wait_video(&session, 1);
    assert!(
        back.first().is_some_and(|frame| frame.pts_us < 500_000),
        "seek back returned {:?}",
        back.first().map(|frame| frame.pts_us)
    );
}

#[test]
fn path_gate_refuses_non_local_and_non_regular_paths() {
    for path in [
        "relative.mp4",
        "res://movie.ogv",
        "user://movie.ogv",
        "https://example.com/movie.mp4",
        "",
    ] {
        let error = probe(path).unwrap_err();
        assert_eq!(error.code(), MediaErrorCode::BadPath, "{path:?}");
    }
    let directory = std::env::temp_dir();
    let error = probe(&directory.to_string_lossy()).unwrap_err();
    assert_eq!(error.code(), MediaErrorCode::BadPath);
    let missing = directory.join("gpty-media-definitely-missing.mp4");
    let error = probe(&missing.to_string_lossy()).unwrap_err();
    assert_eq!(error.code(), MediaErrorCode::BadPath);
}

#[test]
fn garbage_and_truncated_files_fail_without_panicking() {
    let dir = std::env::temp_dir();
    let garbage = dir.join(format!("gpty-media-garbage-{}.bin", std::process::id()));
    std::fs::write(&garbage, b"this is not a media file, not even close").unwrap();
    let error = probe(&garbage.to_string_lossy()).unwrap_err();
    assert!(
        matches!(
            error.code(),
            MediaErrorCode::OpenFailed
                | MediaErrorCode::UnsupportedContainer
                | MediaErrorCode::UnsupportedCodec
        ),
        "garbage error: {error}"
    );
    std::fs::remove_file(&garbage).ok();

    let source = std::fs::read(fixture("h264.mp4")).unwrap();
    let truncated = dir.join(format!("gpty-media-truncated-{}.mp4", std::process::id()));
    std::fs::write(&truncated, &source[..64.min(source.len())]).unwrap();
    let error = probe(&truncated.to_string_lossy()).unwrap_err();
    assert!(
        matches!(
            error.code(),
            MediaErrorCode::OpenFailed
                | MediaErrorCode::UnsupportedContainer
                | MediaErrorCode::UnsupportedCodec
        ),
        "truncated error: {error}"
    );
    std::fs::remove_file(&truncated).ok();
}

#[test]
fn config_is_validated_before_a_worker_starts() {
    let mut config = OpenConfig::new(fixture("h264.mp4"));
    config.sample_rate = 1_000;
    assert_eq!(open_err(config).code(), MediaErrorCode::TooLarge);

    let mut config = OpenConfig::new(fixture("h264.mp4"));
    config.channels = 9;
    assert_eq!(open_err(config).code(), MediaErrorCode::TooLarge);

    let mut config = OpenConfig::new(fixture("h264.mp4"));
    config.max_width = 100_000;
    assert_eq!(open_err(config).code(), MediaErrorCode::TooLarge);
}

#[test]
fn dropping_a_session_while_it_has_queued_frames_does_not_hang() {
    let started = Instant::now();
    let session = MediaSession::open(OpenConfig::new(fixture("long_h264.mp4"))).unwrap();
    // Do not poll: the worker fills its bounded queue and waits on it.
    thread::sleep(Duration::from_millis(100));
    drop(session);
    assert!(
        started.elapsed() < Duration::from_secs(3),
        "dropping the session took {:?}",
        started.elapsed()
    );
}
