//! One media session: a decode thread, bounded queues, and a polled status.
//!
//! The thread owns the FFmpeg input and decoder contexts for its whole life.
//! The caller owns the session handle and polls the queues; when a queue is
//! full the worker blocks in `send_timeout` (checking the stop flag), which is
//! backpressure, not loss. Closing drops the handle, sets the flag, and joins.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, SyncSender, TryRecvError, TrySendError, sync_channel};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use ffmpeg_the_third as ffmpeg;

use crate::error::MediaError;
use crate::probe::{AudioStream, OpenedInput, VideoStream, frame_time_us, open_input};
use crate::{
    MAX_CHANNELS, MAX_FRAME_BYTES, MAX_SAMPLE_RATE, MAX_VIDEO_DIMENSION, MIN_SAMPLE_RATE,
    OPEN_TIMEOUT_MS,
};

/// Frames buffered ahead of the UI. Two 4K frames is already the largest
/// allocation the session will make without the caller consuming.
const VIDEO_QUEUE_FRAMES: usize = 2;
/// Audio chunks buffered ahead of the UI (each chunk is ~2048 frames).
const AUDIO_QUEUE_CHUNKS: usize = 16;
/// Interleaved frames accumulated per audio chunk before it is queued.
const AUDIO_CHUNK_FRAMES: usize = 2048;
/// How often a worker blocked on a full queue re-checks `stop`.
const SEND_POLL: Duration = Duration::from_millis(5);
/// Longest a seek caller waits for room in the worker's command queue.
const COMMAND_TIMEOUT: Duration = Duration::from_millis(50);

#[derive(Debug, Clone)]
pub struct OpenConfig {
    pub path: String,
    /// Output sample rate. The caller passes the rate its audio sink uses.
    pub sample_rate: u32,
    pub channels: u16,
    /// Downscale to fit this box while preserving aspect. Zero means native.
    pub max_width: u32,
    pub max_height: u32,
}

impl OpenConfig {
    pub fn new(path: impl Into<String>) -> Self {
        Self {
            path: path.into(),
            sample_rate: 48_000,
            channels: 2,
            max_width: 0,
            max_height: 0,
        }
    }

    fn validate(&self) -> Result<(), MediaError> {
        if !(MIN_SAMPLE_RATE..=MAX_SAMPLE_RATE).contains(&self.sample_rate) {
            return Err(MediaError::too_large(format!(
                "sample rate {} is outside {}..={MAX_SAMPLE_RATE}",
                self.sample_rate, MIN_SAMPLE_RATE
            )));
        }
        if self.channels == 0 || self.channels > MAX_CHANNELS {
            return Err(MediaError::too_large(format!(
                "channel count {} is outside 1..={MAX_CHANNELS}",
                self.channels
            )));
        }
        if self.max_width > MAX_VIDEO_DIMENSION || self.max_height > MAX_VIDEO_DIMENSION {
            return Err(MediaError::too_large(format!(
                "requested frame box {}x{} exceeds {MAX_VIDEO_DIMENSION}",
                self.max_width, self.max_height
            )));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionState {
    Opening,
    Playing,
    Finished,
    Failed,
}

impl SessionState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Opening => "opening",
            Self::Playing => "playing",
            Self::Finished => "finished",
            Self::Failed => "failed",
        }
    }
}

#[derive(Debug, Clone)]
pub struct VideoFrame {
    pub width: u32,
    pub height: u32,
    pub pts_us: u64,
    pub keyframe: bool,
    /// Tightly packed RGBA8, `width * height * 4` bytes.
    pub data: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct AudioChunk {
    pub sample_rate: u32,
    pub channels: u16,
    pub pts_us: u64,
    /// Interleaved f32 samples.
    pub data: Vec<f32>,
}

impl AudioChunk {
    pub fn frames(&self) -> usize {
        if self.channels == 0 {
            0
        } else {
            self.data.len() / self.channels as usize
        }
    }
}

#[derive(Debug, Clone)]
pub struct SessionStatus {
    pub state: SessionState,
    pub position_us: u64,
    pub duration_us: Option<u64>,
    pub info: Option<crate::MediaInfo>,
    pub error: Option<MediaError>,
}

#[derive(Default)]
struct StatusInner {
    state: Option<SessionState>,
    position_us: u64,
    info: Option<crate::MediaInfo>,
    error: Option<MediaError>,
}

struct Shared {
    stop: Arc<AtomicBool>,
    /// Incremented when the worker applies a seek. Frames carry the epoch
    /// they were queued under; `poll_*` discards everything older.
    epoch: AtomicU64,
    inner: Mutex<StatusInner>,
}

impl Shared {
    fn new() -> Self {
        Self {
            stop: Arc::new(AtomicBool::new(false)),
            epoch: AtomicU64::new(0),
            inner: Mutex::new(StatusInner {
                state: Some(SessionState::Opening),
                ..StatusInner::default()
            }),
        }
    }

    fn set_ready(&self, info: crate::MediaInfo) {
        if let Ok(mut guard) = self.inner.lock() {
            guard.state = Some(SessionState::Playing);
            guard.info = Some(info);
        }
    }

    fn set_position(&self, position_us: u64) {
        if let Ok(mut guard) = self.inner.lock() {
            guard.position_us = guard.position_us.max(position_us);
        }
    }

    fn finish(&self) {
        if let Ok(mut guard) = self.inner.lock() {
            guard.state = Some(SessionState::Finished);
        }
    }

    fn next_epoch(&self) -> u64 {
        self.epoch.fetch_add(1, Ordering::Relaxed) + 1
    }

    fn set_playing(&self) {
        if let Ok(mut guard) = self.inner.lock() {
            guard.state = Some(SessionState::Playing);
            guard.error = None;
        }
    }

    fn fail(&self, error: MediaError) {
        if let Ok(mut guard) = self.inner.lock() {
            guard.state = Some(SessionState::Failed);
            guard.error = Some(error);
        }
    }

    fn status(&self) -> SessionStatus {
        let guard = match self.inner.lock() {
            Ok(guard) => guard,
            Err(_) => {
                return SessionStatus {
                    state: SessionState::Failed,
                    position_us: 0,
                    duration_us: None,
                    info: None,
                    error: Some(MediaError::io("media status lock poisoned")),
                };
            }
        };
        SessionStatus {
            state: guard.state.unwrap_or(SessionState::Opening),
            position_us: guard.position_us,
            duration_us: guard.info.as_ref().and_then(|info| info.duration_us),
            info: guard.info.clone(),
            error: guard.error.clone(),
        }
    }
}

enum Command {
    /// Target position and the acknowledgement the caller waits for. Waiting
    /// for the worker to apply the seek is what lets the caller drop every
    /// queued pre-seek frame without racing the decode loop.
    Seek(u64, SyncSender<Result<(), MediaError>>),
    Stop,
}

enum Startup {
    Ready,
    Failed(MediaError),
}

struct QueuedVideo {
    epoch: u64,
    frame: VideoFrame,
}

struct QueuedAudio {
    epoch: u64,
    chunk: AudioChunk,
}

/// Per-stream position state across a seek. Video and audio keep separate
/// skip deadlines because the demuxer may land the two streams on different
/// keyframes.
#[derive(Default)]
struct VideoCursor {
    last_pts_us: u64,
    skip_until: Option<u64>,
}

#[derive(Default)]
struct AudioCursor {
    skip_until: Option<u64>,
}

/// A live media session. Dropping it stops the worker and joins it.
pub struct MediaSession {
    commands: SyncSender<Command>,
    video_rx: Receiver<QueuedVideo>,
    audio_rx: Receiver<QueuedAudio>,
    ready_rx: Option<Receiver<Startup>>,
    shared: Arc<Shared>,
    worker: Option<JoinHandle<()>>,
}

impl MediaSession {
    /// Open and wait for the stream information. This is the test-friendly
    /// form; the GUI uses [`Self::start`] so a crafted file cannot block the
    /// Godot thread for the open/probe budget.
    pub fn open(config: OpenConfig) -> Result<Self, MediaError> {
        let mut session = Self::start(config)?;
        session.wait_ready()?;
        Ok(session)
    }

    /// Start a session and return immediately. The worker reports `Opening`,
    /// then `Playing` with `info`, or `Failed` with an error in `status()`.
    /// The path and configuration are still validated synchronously.
    pub fn start(config: OpenConfig) -> Result<Self, MediaError> {
        config.validate()?;
        crate::validate_path(&config.path)?;
        let (command_tx, command_rx) = sync_channel(8);
        let (video_tx, video_rx) = sync_channel(VIDEO_QUEUE_FRAMES);
        let (audio_tx, audio_rx) = sync_channel(AUDIO_QUEUE_CHUNKS);
        let (ready_tx, ready_rx) = sync_channel(1);
        let shared = Arc::new(Shared::new());
        let worker_shared = shared.clone();
        let worker = thread::Builder::new()
            .name("gpty-media".to_string())
            .spawn(move || {
                worker_main(
                    config,
                    command_rx,
                    video_tx,
                    audio_tx,
                    ready_tx,
                    worker_shared,
                )
            })
            .map_err(|e| MediaError::io(format!("cannot start media worker: {e}")))?;

        Ok(Self {
            commands: command_tx,
            video_rx,
            audio_rx,
            ready_rx: Some(ready_rx),
            shared,
            worker: Some(worker),
        })
    }

    fn wait_ready(&mut self) -> Result<(), MediaError> {
        let Some(ready_rx) = self.ready_rx.take() else {
            return Ok(());
        };
        match ready_rx.recv_timeout(Duration::from_millis(OPEN_TIMEOUT_MS + 1_000)) {
            Ok(Startup::Ready) => Ok(()),
            Ok(Startup::Failed(error)) => {
                self.stop_and_join();
                Err(error)
            }
            Err(_) => {
                self.stop_and_join();
                Err(MediaError::open("timed out opening media"))
            }
        }
    }

    pub fn status(&self) -> SessionStatus {
        self.shared.status()
    }

    /// Ask the worker to seek to `position_us`. The seek is applied before the
    /// next packet; already-decoded frames are dropped by the decoder flush.
    pub fn seek(&self, position_us: u64) -> Result<(), MediaError> {
        if self.shared.stop.load(Ordering::Relaxed) {
            return Err(MediaError::closed());
        }
        let (ack_tx, ack_rx) = sync_channel(1);
        let mut ack_tx = Some(ack_tx);
        let deadline = std::time::Instant::now() + COMMAND_TIMEOUT;
        loop {
            let sender = ack_tx.take().expect("seek ack sender missing");
            match self.commands.try_send(Command::Seek(position_us, sender)) {
                Ok(()) => break,
                Err(TrySendError::Full(Command::Seek(_, sender))) => {
                    ack_tx = Some(sender);
                    if std::time::Instant::now() >= deadline {
                        return Err(MediaError::seek("decode worker is busy"));
                    }
                    thread::sleep(Duration::from_millis(5));
                }
                Err(TrySendError::Full(_)) => {
                    return Err(MediaError::seek("decode worker is busy"));
                }
                Err(TrySendError::Disconnected(_)) => return Err(MediaError::closed()),
            }
        }
        // The worker only checks commands between packets, and it may be
        // blocked on a full output queue; draining here both discards the
        // stale frames and lets it reach the command check. Waiting without
        // draining would deadlock the two of us.
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        loop {
            match ack_rx.try_recv() {
                Ok(Ok(())) => {
                    // Frames queued before the seek carry the previous
                    // epoch; `poll_*` discards them, so draining here would
                    // also throw away valid post-seek frames.
                    return Ok(());
                }
                Ok(Err(error)) => return Err(error),
                Err(TryRecvError::Disconnected) => {
                    return Err(MediaError::seek("decode worker ended"));
                }
                Err(TryRecvError::Empty) => {
                    while self.video_rx.try_recv().is_ok() {}
                    while self.audio_rx.try_recv().is_ok() {}
                    if std::time::Instant::now() >= deadline {
                        return Err(MediaError::seek("decode worker did not answer the seek"));
                    }
                    thread::sleep(Duration::from_millis(2));
                }
            }
        }
    }

    /// Drain up to `max_frames` decoded frames. Never blocks.
    pub fn poll_video(&self, max_frames: usize) -> Vec<VideoFrame> {
        let epoch = self.shared.epoch.load(Ordering::Relaxed);
        let mut frames = Vec::new();
        for _ in 0..max_frames {
            match self.video_rx.try_recv() {
                Ok(queued) if queued.epoch == epoch => frames.push(queued.frame),
                Ok(_) => continue,
                Err(TryRecvError::Empty | TryRecvError::Disconnected) => break,
            }
        }
        frames
    }

    /// Drain up to `max_chunks` decoded audio chunks. Never blocks.
    pub fn poll_audio(&self, max_chunks: usize) -> Vec<AudioChunk> {
        let epoch = self.shared.epoch.load(Ordering::Relaxed);
        let mut chunks = Vec::new();
        for _ in 0..max_chunks {
            match self.audio_rx.try_recv() {
                Ok(queued) if queued.epoch == epoch => chunks.push(queued.chunk),
                Ok(_) => continue,
                Err(TryRecvError::Empty | TryRecvError::Disconnected) => break,
            }
        }
        chunks
    }

    fn stop_and_join(&mut self) {
        self.shared.stop.store(true, Ordering::Relaxed);
        let _ = self.commands.try_send(Command::Stop);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

impl Drop for MediaSession {
    fn drop(&mut self) {
        self.stop_and_join();
    }
}

fn worker_main(
    config: OpenConfig,
    commands: Receiver<Command>,
    video_tx: SyncSender<QueuedVideo>,
    audio_tx: SyncSender<QueuedAudio>,
    ready_tx: SyncSender<Startup>,
    shared: Arc<Shared>,
) {
    let opened = match open_input(&config.path, shared.stop.clone()) {
        Ok(opened) => opened,
        Err(error) => {
            shared.fail(error.clone());
            let _ = ready_tx.send(Startup::Failed(error));
            return;
        }
    };
    let OpenedInput {
        mut input,
        info,
        mut video,
        mut audio,
    } = opened;
    shared.set_ready(info.clone());
    if ready_tx.send(Startup::Ready).is_err() {
        return;
    }

    let mut video_pipeline = VideoPipeline::new(config.max_width, config.max_height);
    let mut audio_pipeline = AudioPipeline::new(config.sample_rate, config.channels);
    // Frames decoded after a seek may start at the keyframe *before* the
    // target; the cursors drop them until the first frame at or past it.
    let mut video_cursor = VideoCursor::default();
    let mut audio_cursor = AudioCursor::default();

    'session: loop {
        'decode: loop {
            if shared.stop.load(Ordering::Relaxed) {
                return;
            }
            while let Ok(command) = commands.try_recv() {
                match command {
                    Command::Stop => return,
                    Command::Seek(position_us, ack) => {
                        if let Err(error) = seek(
                            &mut input,
                            position_us,
                            video.as_mut(),
                            audio.as_mut(),
                            &mut audio_pipeline,
                        ) {
                            let _ = ack.send(Err(error.clone()));
                            shared.fail(error);
                            break 'decode;
                        }
                        shared.next_epoch();
                        shared.set_position(position_us);
                        video_cursor.last_pts_us = position_us;
                        video_cursor.skip_until = Some(position_us);
                        audio_cursor.skip_until = Some(position_us);
                        // Armed before the caller resumes, so it can drop queued
                        // pre-seek frames and the next frame it receives is one
                        // the skip rule admitted.
                        let _ = ack.send(Ok(()));
                    }
                }
            }

            // A fresh packet each read: `av_read_frame` requires an empty packet,
            // and the previous packet may still be referenced by the decoder.
            let mut packet = ffmpeg::codec::packet::Packet::empty();
            match packet.read(&mut input) {
                Ok(()) => {
                    let stream_index = packet.stream();
                    if let Some(stream) = video.as_mut()
                        && stream_index == stream.index
                        && let Err(error) = decode_video_packet(
                            stream,
                            &packet,
                            &mut video_pipeline,
                            &video_tx,
                            &shared,
                            &mut video_cursor,
                        )
                    {
                        shared.fail(error);
                        return;
                    }
                    if let Some(stream) = audio.as_mut()
                        && stream_index == stream.index
                        && let Err(error) = decode_audio_packet(
                            stream,
                            &packet,
                            &mut audio_pipeline,
                            &audio_tx,
                            &shared,
                            &mut audio_cursor,
                        )
                    {
                        shared.fail(error);
                        return;
                    }
                }
                Err(ffmpeg::Error::Eof) => {
                    let mut error = None;
                    if let Some(stream) = video.as_mut() {
                        let _ = stream.decoder.send_eof();
                        if let Err(e) = drain_video(
                            stream,
                            &mut video_pipeline,
                            &video_tx,
                            &shared,
                            &mut video_cursor,
                            None,
                            false,
                        ) {
                            error = Some(e);
                        }
                    }
                    if let Some(stream) = audio.as_mut() {
                        let _ = stream.decoder.send_eof();
                        if let Err(e) = drain_audio(
                            stream,
                            &mut audio_pipeline,
                            &audio_tx,
                            &shared,
                            &mut audio_cursor,
                        ) {
                            error = Some(e);
                        }
                    }
                    if error.is_none()
                        && let Err(e) = audio_pipeline.flush(&audio_tx, &shared)
                    {
                        error = Some(e);
                    }
                    match error {
                        Some(error) => {
                            shared.fail(error);
                            return;
                        }
                        None => {
                            shared.finish();
                            break 'decode;
                        }
                    }
                }
                Err(error) => {
                    shared.fail(MediaError::decode(format!("read failed: {error}")));
                    return;
                }
            }
        }

        // Finished: stay alive so a seek/replay from the transport controls
        // can restart decoding. Without this, a seek after the last frame
        // would race the worker's exit and answer `closed`.
        loop {
            if shared.stop.load(Ordering::Relaxed) {
                return;
            }
            match commands.recv_timeout(Duration::from_millis(100)) {
                Ok(Command::Stop) => return,
                Ok(Command::Seek(position_us, ack)) => {
                    match seek(
                        &mut input,
                        position_us,
                        video.as_mut(),
                        audio.as_mut(),
                        &mut audio_pipeline,
                    ) {
                        Ok(()) => {
                            shared.set_playing();
                            shared.next_epoch();
                            shared.set_position(position_us);
                            video_cursor.last_pts_us = position_us;
                            video_cursor.skip_until = Some(position_us);
                            audio_cursor.skip_until = Some(position_us);
                            let _ = ack.send(Ok(()));
                            continue 'session;
                        }
                        Err(error) => {
                            let _ = ack.send(Err(error.clone()));
                            shared.fail(error);
                            return;
                        }
                    }
                }
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => return,
            }
        }
    }
}

fn seek(
    input: &mut ffmpeg::format::context::Input,
    position_us: u64,
    video: Option<&mut VideoStream>,
    audio: Option<&mut AudioStream>,
    audio_pipeline: &mut AudioPipeline,
) -> Result<(), MediaError> {
    let ts = position_us.min(i64::MAX as u64) as i64;
    input
        .seek(ts, ..=ts)
        .map_err(|e| MediaError::seek(format!("seek to {position_us} µs failed: {e}")))?;
    if let Some(stream) = video {
        stream.decoder.flush();
    }
    if let Some(stream) = audio {
        stream.decoder.flush();
    }
    audio_pipeline.reset();
    Ok(())
}

fn decode_video_packet(
    stream: &mut VideoStream,
    packet: &ffmpeg::codec::packet::Packet,
    pipeline: &mut VideoPipeline,
    tx: &SyncSender<QueuedVideo>,
    shared: &Shared,
    cursor: &mut VideoCursor,
) -> Result<(), MediaError> {
    let packet_pts = packet.pts().map(|pts| frame_time_us(pts, stream.time_base));
    let keyframe = packet.is_key();
    match stream.decoder.send_packet(packet) {
        Ok(()) => {}
        Err(error) if is_again(&error) => {
            drain_video(stream, pipeline, tx, shared, cursor, packet_pts, keyframe)?;
            stream
                .decoder
                .send_packet(packet)
                .map_err(|e| MediaError::decode(format!("send packet failed: {e}")))?;
        }
        Err(error) => {
            return Err(MediaError::decode(format!("send packet failed: {error}")));
        }
    }
    drain_video(stream, pipeline, tx, shared, cursor, packet_pts, keyframe)
}

fn drain_video(
    stream: &mut VideoStream,
    pipeline: &mut VideoPipeline,
    tx: &SyncSender<QueuedVideo>,
    shared: &Shared,
    cursor: &mut VideoCursor,
    packet_pts_us: Option<u64>,
    keyframe: bool,
) -> Result<(), MediaError> {
    let mut frame = ffmpeg::frame::Video::empty();
    loop {
        match stream.decoder.receive_frame(&mut frame) {
            Ok(()) => {
                let pts_us = frame
                    .pts()
                    .map(|pts| frame_time_us(pts, stream.time_base))
                    .or(packet_pts_us)
                    .unwrap_or(cursor.last_pts_us);
                cursor.last_pts_us = pts_us;
                if let Some(target) = cursor.skip_until {
                    if pts_us < target {
                        continue;
                    }
                    cursor.skip_until = None;
                }
                let (width, height, data) = pipeline.convert(&frame)?;
                let out = QueuedVideo {
                    epoch: shared.epoch.load(Ordering::Relaxed),
                    frame: VideoFrame {
                        width,
                        height,
                        pts_us,
                        keyframe,
                        data,
                    },
                };
                if !send_bounded(tx, out, shared) {
                    return Err(MediaError::closed());
                }
                shared.set_position(pts_us);
            }
            Err(error) if is_again(&error) => break,
            Err(ffmpeg::Error::Eof) => break,
            Err(error) => {
                return Err(MediaError::decode(format!("video decode failed: {error}")));
            }
        }
    }
    Ok(())
}

fn decode_audio_packet(
    stream: &mut AudioStream,
    packet: &ffmpeg::codec::packet::Packet,
    pipeline: &mut AudioPipeline,
    tx: &SyncSender<QueuedAudio>,
    shared: &Shared,
    cursor: &mut AudioCursor,
) -> Result<(), MediaError> {
    match stream.decoder.send_packet(packet) {
        Ok(()) => {}
        Err(error) if is_again(&error) => {
            drain_audio(stream, pipeline, tx, shared, cursor)?;
            stream
                .decoder
                .send_packet(packet)
                .map_err(|e| MediaError::decode(format!("send packet failed: {e}")))?;
        }
        Err(error) => {
            return Err(MediaError::decode(format!("send packet failed: {error}")));
        }
    }
    drain_audio(stream, pipeline, tx, shared, cursor)
}

fn drain_audio(
    stream: &mut AudioStream,
    pipeline: &mut AudioPipeline,
    tx: &SyncSender<QueuedAudio>,
    shared: &Shared,
    cursor: &mut AudioCursor,
) -> Result<(), MediaError> {
    let mut frame = ffmpeg::frame::Audio::empty();
    loop {
        match stream.decoder.receive_frame(&mut frame) {
            Ok(()) => {
                if let Some(target) = cursor.skip_until {
                    let pts_us = frame
                        .pts()
                        .map(|pts| frame_time_us(pts, stream.time_base))
                        .unwrap_or(target);
                    let duration_us =
                        frame.samples() as u64 * 1_000_000 / frame.rate().max(1) as u64;
                    if pts_us.saturating_add(duration_us) < target {
                        continue;
                    }
                    cursor.skip_until = None;
                }
                let chunks = pipeline.push_frame(&frame, stream.time_base)?;
                for chunk in chunks {
                    let queued = QueuedAudio {
                        epoch: shared.epoch.load(Ordering::Relaxed),
                        chunk,
                    };
                    if !send_bounded(tx, queued, shared) {
                        return Err(MediaError::closed());
                    }
                }
            }
            Err(error) if is_again(&error) => break,
            Err(ffmpeg::Error::Eof) => break,
            Err(error) => {
                return Err(MediaError::decode(format!("audio decode failed: {error}")));
            }
        }
    }
    Ok(())
}

fn send_bounded<T>(tx: &SyncSender<T>, value: T, shared: &Shared) -> bool {
    let mut value = value;
    loop {
        match tx.try_send(value) {
            Ok(()) => return true,
            // The consumer has not caught up: wait, but keep checking the
            // stop flag so a close never waits on a pane that stopped polling.
            Err(TrySendError::Full(returned)) => {
                value = returned;
                if shared.stop.load(Ordering::Relaxed) {
                    return false;
                }
                thread::sleep(SEND_POLL);
            }
            Err(TrySendError::Disconnected(_)) => return false,
        }
    }
}

fn is_again(error: &ffmpeg::Error) -> bool {
    matches!(error, ffmpeg::Error::Other { errno } if *errno == libc::EAGAIN)
}

struct VideoPipeline {
    max_width: u32,
    max_height: u32,
    scaler: Option<ffmpeg::software::scaling::Context>,
    source: Option<(ffmpeg::format::Pixel, u32, u32)>,
    output: Option<(u32, u32)>,
}

impl VideoPipeline {
    fn new(max_width: u32, max_height: u32) -> Self {
        Self {
            max_width,
            max_height,
            scaler: None,
            source: None,
            output: None,
        }
    }

    fn convert(&mut self, frame: &ffmpeg::frame::Video) -> Result<(u32, u32, Vec<u8>), MediaError> {
        let width = frame.width();
        let height = frame.height();
        if width == 0 || height == 0 {
            return Err(MediaError::decode("decoded a zero-sized frame"));
        }
        let (out_w, out_h) = fit_frame(width, height, self.max_width, self.max_height);
        let bytes = (out_w as usize)
            .checked_mul(out_h as usize)
            .and_then(|pixels| pixels.checked_mul(4))
            .ok_or_else(|| MediaError::too_large("frame size overflow"))?;
        if bytes > MAX_FRAME_BYTES {
            return Err(MediaError::too_large(format!(
                "decoded frame {out_w}x{out_h} exceeds the frame cap"
            )));
        }

        let source = (frame.format(), width, height);
        if self.source != Some(source) || self.output != Some((out_w, out_h)) {
            self.scaler = Some(
                ffmpeg::software::scaling::Context::get(
                    frame.format(),
                    width,
                    height,
                    ffmpeg::format::Pixel::RGBA,
                    out_w,
                    out_h,
                    ffmpeg::software::scaling::Flags::BILINEAR,
                )
                .map_err(|e| MediaError::decode(format!("cannot create scaler: {e}")))?,
            );
            self.source = Some(source);
            self.output = Some((out_w, out_h));
        }

        let scaler = self
            .scaler
            .as_mut()
            .ok_or_else(|| MediaError::decode("scaler missing"))?;
        let mut output = ffmpeg::frame::Video::new(ffmpeg::format::Pixel::RGBA, out_w, out_h);
        scaler
            .run(frame, &mut output)
            .map_err(|e| MediaError::decode(format!("scale failed: {e}")))?;

        let stride = output.stride(0);
        let row = out_w as usize * 4;
        let data = output.data(0);
        let mut packed = Vec::with_capacity(bytes);
        for y in 0..out_h as usize {
            let start = y * stride;
            let end = start
                .checked_add(row)
                .ok_or_else(|| MediaError::too_large("row overflow"))?;
            if end > data.len() {
                return Err(MediaError::decode(
                    "scaled frame is shorter than its stride",
                ));
            }
            packed.extend_from_slice(&data[start..end]);
        }
        Ok((out_w, out_h, packed))
    }
}

fn fit_frame(width: u32, height: u32, max_width: u32, max_height: u32) -> (u32, u32) {
    if max_width == 0 || max_height == 0 {
        return (width, height);
    }
    if width <= max_width && height <= max_height {
        return (width, height);
    }
    let scale = (max_width as f64 / width as f64).min(max_height as f64 / height as f64);
    (
        ((width as f64 * scale).round() as u32).max(1),
        ((height as f64 * scale).round() as u32).max(1),
    )
}

struct AudioPipeline {
    target_rate: u32,
    target_channels: u16,
    target_layout: ffmpeg::ChannelLayout<'static>,
    target_mask: ffmpeg::ChannelLayoutMask,
    resampler: Option<ffmpeg::software::resampling::Context>,
    source: Option<(ffmpeg::format::Sample, u32, u32)>,
    acc: Vec<f32>,
    acc_pts_us: u64,
    next_pts_us: u64,
}

impl AudioPipeline {
    fn new(target_rate: u32, target_channels: u16) -> Self {
        let layout = ffmpeg::ChannelLayout::default_for_channels(target_channels as u32);
        let mask = layout.mask().unwrap_or(ffmpeg::ChannelLayoutMask::STEREO);
        Self {
            target_rate,
            target_channels,
            target_layout: layout,
            target_mask: mask,
            resampler: None,
            source: None,
            acc: Vec::new(),
            acc_pts_us: 0,
            next_pts_us: 0,
        }
    }

    /// A seek discards buffered samples and the resampler's delay.
    fn reset(&mut self) {
        self.acc.clear();
        self.resampler = None;
        self.source = None;
        self.acc_pts_us = 0;
        self.next_pts_us = 0;
    }

    fn push_frame(
        &mut self,
        frame: &ffmpeg::frame::Audio,
        time_base: ffmpeg::Rational,
    ) -> Result<Vec<AudioChunk>, MediaError> {
        let source_rate = frame.rate();
        if source_rate == 0 {
            return Err(MediaError::decode("audio frame has no sample rate"));
        }
        if let Some(pts) = frame.pts() {
            self.next_pts_us = frame_time_us(pts, time_base);
        }

        let source = (frame.format(), source_rate, frame.ch_layout().channels());
        if self.source != Some(source) {
            self.resampler = Some(
                ffmpeg::software::resampling::Context::get2(
                    frame.format(),
                    frame.ch_layout().clone(),
                    source_rate,
                    ffmpeg::format::Sample::F32(ffmpeg::format::sample::Type::Packed),
                    self.target_layout.clone(),
                    self.target_rate,
                )
                .map_err(|e| MediaError::decode(format!("cannot create resampler: {e}")))?,
            );
            self.source = Some(source);
        }

        let resampler = self
            .resampler
            .as_mut()
            .ok_or_else(|| MediaError::decode("resampler missing"))?;
        let capacity = ((frame.samples() as u64 * self.target_rate as u64) / source_rate as u64)
            as usize
            + 512;
        let mut output = ffmpeg::frame::Audio::new(
            ffmpeg::format::Sample::F32(ffmpeg::format::sample::Type::Packed),
            capacity,
            self.target_mask,
        );
        resampler
            .run(frame, &mut output)
            .map_err(|e| MediaError::decode(format!("resample failed: {e}")))?;

        let samples = output.samples();
        let channels = self.target_channels as usize;
        let needed = samples
            .checked_mul(channels)
            .and_then(|v| v.checked_mul(4))
            .ok_or_else(|| MediaError::too_large("audio buffer overflow"))?;
        let data = output.data(0);
        let usable = needed.min(data.len());
        let complete = usable - (usable % (channels * 4));
        if self.acc.is_empty() {
            self.acc_pts_us = self.next_pts_us;
        }
        self.acc.extend(
            data[..complete]
                .chunks_exact(4)
                .map(|b| f32::from_ne_bytes([b[0], b[1], b[2], b[3]])),
        );
        self.next_pts_us += samples as u64 * 1_000_000 / source_rate as u64;
        Ok(self.take_full_chunks())
    }

    fn take_full_chunks(&mut self) -> Vec<AudioChunk> {
        let channels = self.target_channels as usize;
        let chunk_samples = AUDIO_CHUNK_FRAMES * channels;
        let mut chunks = Vec::new();
        while self.acc.len() >= chunk_samples {
            let rest = self.acc.split_off(chunk_samples);
            let data = std::mem::replace(&mut self.acc, rest);
            chunks.push(AudioChunk {
                sample_rate: self.target_rate,
                channels: self.target_channels,
                pts_us: self.acc_pts_us,
                data,
            });
            self.acc_pts_us += AUDIO_CHUNK_FRAMES as u64 * 1_000_000 / self.target_rate as u64;
        }
        chunks
    }

    fn flush(&mut self, tx: &SyncSender<QueuedAudio>, shared: &Shared) -> Result<(), MediaError> {
        if let Some(mut resampler) = self.resampler.take() {
            // Drain FFmpeg's resampler delay before emitting the tail.
            loop {
                let mut output = ffmpeg::frame::Audio::new(
                    ffmpeg::format::Sample::F32(ffmpeg::format::sample::Type::Packed),
                    AUDIO_CHUNK_FRAMES,
                    self.target_mask,
                );
                match resampler.flush(&mut output) {
                    Ok(Some(_)) => {
                        self.append_output(&output);
                    }
                    Ok(None) => break,
                    Err(error) => {
                        return Err(MediaError::decode(format!(
                            "resample flush failed: {error}"
                        )));
                    }
                }
            }
            self.resampler = Some(resampler);
        }
        for chunk in self.take_full_chunks() {
            let queued = QueuedAudio {
                epoch: shared.epoch.load(Ordering::Relaxed),
                chunk,
            };
            if !send_bounded(tx, queued, shared) {
                return Err(MediaError::closed());
            }
        }
        if !self.acc.is_empty() {
            let data = std::mem::take(&mut self.acc);
            let chunk = AudioChunk {
                sample_rate: self.target_rate,
                channels: self.target_channels,
                pts_us: self.acc_pts_us,
                data,
            };
            let queued = QueuedAudio {
                epoch: shared.epoch.load(Ordering::Relaxed),
                chunk,
            };
            if !send_bounded(tx, queued, shared) {
                return Err(MediaError::closed());
            }
        }
        Ok(())
    }

    fn append_output(&mut self, output: &ffmpeg::frame::Audio) {
        let channels = self.target_channels as usize;
        let samples = output.samples();
        let needed = samples.saturating_mul(channels).saturating_mul(4);
        let data = output.data(0);
        let usable = needed.min(data.len());
        let complete = usable - (usable % (channels * 4));
        self.acc.extend(
            data[..complete]
                .chunks_exact(4)
                .map(|b| f32::from_ne_bytes([b[0], b[1], b[2], b[3]])),
        );
    }
}
