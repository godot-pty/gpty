# gpty-media

Media probe and decode backend for gpty's media pane. It is the only crate
that links FFmpeg; `gpty-gdext` exposes it as the `GptyMedia` node, and the
pane consumes packed RGBA frames and interleaved f32 samples.

## API

- `probe(path) -> MediaInfo` — container, duration, streams, selected codecs.
- `MediaSession::open(OpenConfig)` / `start(OpenConfig)` — starts one decode
  thread; `open` waits for stream info, `start` returns immediately. `video`
  and `audio` select which decoders run (default both): a caller that polls
  only one queue must turn the other off, because an unconsumed queue is
  backpressure and would stall the stream it is not reading.
- `poll_video(max)` / `poll_audio(max)` — non-blocking drains of bounded
  queues. A full queue blocks the decoder, not the caller.
- `seek(position_us)` — acknowledged by the worker before it returns, so
  already-queued pre-seek output is discarded by epoch and the next item is
  from the new position.
- `SessionStatus` — state, position, duration, stream info and the last
  error. `Finished` keeps the worker alive so a seek/replay can restart it.

Video frames are tightly packed RGBA8 (`width * height * 4`); audio chunks are
interleaved f32 at the caller's requested rate and channel count. Timestamps
are microseconds.

## Trust boundary

A path is untrusted input (layout, profile, IPC). `validate_path` requires an
absolute local **regular file** — no scheme, no FIFO/device — and the demuxer
and codec allowlists in `src/lib.rs` are checked after FFmpeg opens the file.
`components.txt` is the closed component set compiled into the shipped FFmpeg;
`tests/build_recipe.rs` checks it against the runtime lists in both directions.

Caps: at most 16 streams, 4096 px per video side, 8192 audio channels (the
session config accepts up to 8), 48 MB per frame budget (`MAX_FRAME_BYTES`),
bounded queues (2 video frames / 16 audio chunks), and a 10 s open/probe
deadline. No hardware decode and no network protocols are compiled in.

## Binding rules

`ffmpeg-the-third` is used through a deliberately narrow subset. Do not use:

- `Input::packets()` — its iterator relies on `repr(Rust)` field order;
  packets are read with `Packet::read` + a stream lookup instead.
- container metadata — file-controlled bytes are not necessarily UTF-8.
- frame dimension setters, `sample::Buffer`, filters or subtitles.

`tests/binding_rules.rs` fails if one of those calls is reintroduced in
`src/session.rs` or `src/probe.rs`.

## Build

Run `./scripts/media-deps` from the repository root. It downloads pinned
FFmpeg 9.0.2, builds the LGPLv3 shared libraries from `components.txt`, and
writes `dist/ffmpeg/<platform>-<arch>/env.sh`. Tests decode the committed
fixtures in `tests/fixtures/` (generated from FFmpeg's `lavfi` sources).
