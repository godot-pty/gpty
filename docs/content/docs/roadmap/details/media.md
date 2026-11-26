---
title: "Roadmap details - MEDIA"
weight: 900
build:
  list: never
---

Every MEDIA row, by ID and in allocation order. The queue and its priority live on the release chain pages; this page is the evidence behind each row.

## MEDIA-1

**Media pane type** - `media` in `PaneTypes.ALL`; plays local audio/video from an absolute file path validated by `sanitize_tile` (same trust rule as code_viewer/file_tree). Remote/URL streaming deferred - a separate trust boundary. `media` is an eighth pane type on both sides of the vocabulary seam - `PaneType` (variant, `as_str`, `FromStr`, `ALL: [PaneType; 8]`) and `PaneTypes.ALL` (appended last in both, the order the key-for-key seam test enforces), plus `TerminalManager._PaneScripts` - so the sidebar, palette (`new media`), `gpty new-pane -t media`, the swap menu, `M<n>` labels and the plugin-manifest validator all carry it with no second list. The new `MediaPane` plays local files through Godot's native streams: Theora `.ogv` video and Ogg Vorbis/MP3/WAV audio (`.ogg`/`.oga`/`.mp3`/`.wav`), with the file name and Playing/Finished state shown in the pane and a real letterboxed video surface (`AspectRatioContainer` given the clip's own ratio - a bare `VideoStreamPlayer.expand` is a cover fit and cropped a 4:3 clip in a tall pane, measured in the live capture). `MediaFiles` is the one closed table and path gate - absolute, `FileAccess.file_exists`'s regular-file check, known extension - and the pane builds a typed stream (`VideoStreamTheora.file` / the three audio static loaders) rather than handing the path to `ResourceLoader`, because a file-supplied `.gd` or `.tscn` behind a media extension would be loaded as code; remote URLs and `res://`/`user://` are refused with an in-pane explanation, and a refusal clears `file_path` instead of pretending the pane still shows a file. The file tree's in-app route now covers media (`ViewableFiles` first, then `MediaFiles.pane_for`), and a same-path request focuses the media pane already playing it (two would double the sound and the decode work). A media tile restores its path and starts playing; clearing the settings path returns to the idle view. The eighth sidebar button was clipped by the old one-row strip (found in the live capture), so the Add Pane buttons are a 4×2 `GridContainer` now, pinned by a sidebar width assertion. Native-transport scope is deliberate: the Rust demux/decode matrix, wider containers/codecs, transport controls and `paneStatus` state are the remaining v0.7.0 media items below, and the CLI/agent file-opening gap is queued there too. Verified: `test_media_files.gd` (the table and every path-gate branch), `test_media_pane.gd` (audio and video actually playing in headless - `AudioStreamPlayer.playing` and `VideoStreamPlayer.is_playing()` - plus refusals before a decoder, idle/clear, layout state and no routed content), `test_pane_file_sinks.gd` (the media route), `test_pane_open_request.gd` (same-file focus), `test_layout_restore.gd` (a media tile restores and plays), the pane-spawning/label and sidebar updates, `cargo test -p gpty-core -p gpty -p gpty-ipc` green (including both vocabulary seam tests), `gut-check: OK - 59 scripts, 764 tests`, the live smoke's new `media` step (`new-pane -t media` reports the type), and a real-window capture showing the letterboxed video, the playing status and the two-row pane buttons.

Commits: d17bac7

## MEDIA-2

**Rust media backend** - a new `gpty-media` crate owns the only FFmpeg binding (`ffmpeg-the-third` 6.0.0, pinned behind a facade), and `GptyMedia` is the JSON + packed-array FFI edge. Integration decision from the review: a SHA256-pinned FFmpeg 9.0.2 built **shared, LGPLv3** (`--disable-everything --disable-network`, the closed component set in `crates/gpty-media/components.txt`) and bundled per platform; `ffmpeg-the-third` was chosen over maintenance-mode `ffmpeg-next` for its active soundness work, with `ffmpeg-next` documented as the fallback. Decode: H.264/HEVC/VP8/VP9/AV1/Theora video to packed RGBA8, MP3/FLAC/Vorbis/Opus/AAC/ALAC/AC-3/PCM to interleaved f32 at the requested rate/channels; one acknowledged-seek worker thread per file with bounded queues, epoch filtering and per-stream cursors that drop pre-target frames, and a worker that survives EOF for replay. Trust: the Rust path gate (absolute local regular file), demuxer-alias and codec-id allowlists, 16 streams / 4096 px / 34 MiB frame / 8 channels / 10 s open caps, and no network protocols in the build. Evidence: 16 Rust tests (decode/seek/path/refusal/backpressure plus the `build_recipe.rs` and `binding_rules.rs` seams), the three-test `GptyMedia` GUT smoke, and a local link against the vendored prefix (`ldd` resolves the bundle path). **Known gap:** release artifacts do not yet bundle the runtime libraries - queued next.

Commits: d17bac7

## MEDIA-3

**Bundle the pinned FFmpeg runtime into release artifacts** - `scripts/bundle-media` is the one packer: `linux`/`windows` copy the pinned `libav*`/`libsw*`/DLLs beside the GDExtension and run an `ldd` "not found" check, `macos-libs` lipos the two per-arch builds into universal dylibs and ad-hoc signs them, and `macos-zip` injects them into the exported `.app` (so it can run on the Linux export job without touching a signature). The macOS FFmpeg build uses `--install-name-dir=@rpath` plus `@loader_path`, and `macos-libs` fails if a GDExtension still links FFmpeg by absolute path. `scripts/build` calls the same helper for the host bundle; release build jobs upload `release/ffmpeg`, a new `bundle-macos` job produces the universal set, and the three export steps bundle before archiving. FFmpeg's LGPLv3/LGPLv2.1 texts and the component list travel in `licenses/`, and the AUR recipe installs the libs and licenses under `/usr/lib/gpty` and `/usr/share/licenses/gpty`. **Verified:** a locally exported Linux bundle extracted to a fresh directory resolves every library from `$ORIGIN` and starts headless with `LD_LIBRARY_PATH` unset. macOS and Windows bundling are wired but only exercised by the first tagged release; macOS real signing (v1.0.0) must run after injection. Windows still uses vcpkg's FFmpeg (wider internal codec set; the runtime allowlist gates use), queued below.

Commits: d17bac7

## MEDIA-4

**Video rendering** - the media pane now renders the Rust backend's frames instead of a `VideoStreamPlayer`. `MediaFiles` widened the video table to `ogv/mp4/m4v/mov/mkv/webm/avi/ts/m2ts` (Theora moved to the same backend, so there is one video path), and `GptyMedia` was opened with `audio: false` at this stage (an unconsumed audio queue is backpressure; the Audio playback item below removed the limitation and opens both streams). Frames are drained in a bounded batch per `_process`, held in a small PTS-ordered backlog, and presented against `Time.get_ticks_usec()` (a decoder that runs ahead must not play the clip at 4×); a stale frame is dropped only when a newer one is waiting. The surface is a `TextureRect` with aspect-preserving center stretch (the old `AspectRatioContainer` fit without needing dimensions before the first frame), and `ImageTexture.update` reuses the texture when the size is unchanged. The backend's probe stays off the GUI thread; status failure clears the pane's file exactly like a refused path. **Verified:** `test_media_pane.gd` decodes the crate's 64×48 MP4 and the five-second Theora fixture to a non-null 64×48 texture through `GptyMedia`, the file-table tests cover the expanded list, and the full GUT suite is green (`773 tests`). Audio for video files is silent until the next item.

Commits: d17bac7

## MEDIA-5

**Audio playback** - every audio format in the table (`ogg/oga/opus/mp3/wav/flac/m4a/aac`) now decodes through `gpty-media` and is pushed into an `AudioStreamGenerator` at 48 kHz stereo with a 0.2 s buffer; the native `AudioStreamOggVorbis`/`MP3`/`WAV` loaders are gone, so the pane has one backend. Chunks are pushed while the generator has room, with a bounded 32-chunk local lead: leaving the backend audio queue full would block the worker, and that worker also decodes video. When audio is running, the video clock is the player's `get_playback_position()` mapped from the first chunk's PTS (20 ms present tolerance, 150 ms catch-up drop); without audio the monotonic start clock is used. Volume (`-40..6 dB`) and mute (mute = -80 dB) are pane settings carried in layout state. A generated 8-bit mono WAV exposed two backend gaps that are now pinned by `an_unspecified_source_layout_is_normalized`: `pcm_u8` was missing from the component set, and a layout-less frame must be normalized **on the frame** as well as on the resampler (swresample answers `InputChanged` otherwise). **Verified:** 15 `gpty-media` session tests, the GUT audio/A-V/volume tests and the restore test (which now waits for the first chunk instead of assuming synchronous playback), and the full suite (`775 tests`). Transport controls (pause/seek/loop, `paneStatus`) are the remaining media item.

Commits: d17bac7

## MEDIA-6

**Playback controls** - the media pane has a transport bar (Play/Pause, seek slider, elapsed/total, Loop). Pause pauses the audio generator and freezes the media clock; a video-only pane offsets its monotonic clock on resume, so a pause consumes no media time. Seek uses the backend's acknowledged seek, clears the pane's frame/audio queues and the generator buffer, and resets the clock epoch; the slider is marked dragging so the position label does not fight the user. Loop seeks to 0 when the backend finishes (the worker survives EOF) and is saved in layout state; Play on a finished non-looping file restarts it. `PaneBody.status_document()` is the generic `paneStatus` hook: `TerminalPane` returns its process/grid document and `MediaPane` returns `{kind,file,state,position_us,duration_us,paused,loop,volume_db,muted}`; the aggregate and single-pane IPC paths both use it, and a pane with no primitives still reports `status: null` / a "no status primitives" error. **Verified:** GUT pause (position frozen), seek (position moves to the target), loop (restart observed) and status tests, the updated IPC contract test, and the full suite (`777 tests`).

Commits: d17bac7

## MEDIA-7

**Format matrix** - the Rust backend covers MP4/MOV/MKV/WebM/OGG/WAV/FLAC/MP3/AAC/AVI/MPEG-TS containers, H.264/HEVC/VP8/VP9/AV1/Theora video, and MP3/FLAC/Vorbis/Opus/AAC/ALAC/AC-3/PCM audio (`components.txt`); the pane exposes it through `MediaFiles` and the GUT fixtures decode every allowed video codec (H.264, HEVC, VP9, AV1, Theora) plus the audio set. Windows uses vcpkg's wider build (queued to narrow); the runtime allowlist is identical on every platform. Per-platform decoder verification beyond Linux is the release check, not an open implementation item.

Commits: d17bac7

## MEDIA-8

**Media security notes in AGENTS.md** - the media bullet and a new security bullet in AGENTS.md, plus SECURITY.md's Hardening and Known limitations sections, state the FFmpeg exception honestly (in-process C decoders, no sandbox claim), the pinned minimal LGPLv3 build (`--disable-everything --disable-network`), the Rust path/demuxer/codec gates, the size/queue/open caps, and that hardware decode is off. The earlier "memory-safe/audited decoders only" wording was replaced by the owner's FFmpeg decision, so the policy and the code cannot disagree.

Commits: d17bac7

## MEDIA-9

**Standalone by design** - the media backend is its own crate and Godot class; no other feature consumes it, its failure is localized to the media pane, and its build dependency (`scripts/media-deps`) is limited to jobs that compile the extension. The release packaging (also closed) carries the runtime privately, so no other release surface depends on FFmpeg.

Commits: d17bac7

## MEDIA-10

**A decoder call that never returns hangs the pane close, and nothing bounds it** - **measured, then closed** 2026-11-01. Reproduced first: a `#[cfg(test)]` seam parks the worker where its first libavcodec call runs (`Packet::read`, `send_packet` and `receive_frame` are calls into C, and the open deadline's interrupt callback is cleared once the file is open, so `stop` is unreadable from inside one), and the session is then dropped - which is what a pane close and the window quit both do. On HEAD the drop never returned: the test was still running at 60 s and the run was killed at 300 s. `stop_and_join` now hands to `join_worker`, which sets `stop`, sends `Stop` (waking the worker out of a full queue or the finished-state wait) and joins for at most `CLOSE_TIMEOUT_MS` = 2 s, re-checking `JoinHandle::is_finished` every 10 ms; past that it logs and drops the handle, which detaches the thread. Nothing frees FFmpeg contexts under a running decoder: the abandoned thread frees its own when the call returns, and leaks only if the call never does. `session::tests::a_stuck_decode_call_does_not_hold_the_close` measures the drop at ~2.0 s, asserts the worker had **not** returned at that moment (the bound ended the wait, not luck) and that it exits by itself after release; the healthy path is unchanged (`dropping_a_session_while_it_has_queued_frames_does_not_hang`, all 17 `tests/session.rs` cases, `cargo test -p gpty-media`). Direction (2) - a watchdog that fails the session for the user - buys nothing here: a detached worker exists only after its session was dropped, so nothing polls its status; the reason goes to `warn` instead. Direction (3), a decode process, stays unbuilt: no real file has been shown to trigger this, and the seam is what a fixture would have to replace. Documented in `crates/gpty-media/README.md` (open deadline and close budget), `security.md`, `pitfalls.md` and the architecture note; changelog line owed at release time: closing a media pane can no longer wait forever on a decoder.

Commits: 3d33b77, ed4e2bc

## MEDIA-11

**A seek freezes the GUI for five seconds when the decoder is stuck** - measured first, then closed 2026-11-01 by never waiting for the worker. The old `MediaSession::seek` blocked its caller for an acknowledgement with a 5 s deadline; with the worker parked in a decode call (`stuck::park()`) the new test observed `SeekFailed: "decode worker did not answer the seek"` after the full deadline and a 7.00 s test body. The seek now claims a serial (`begin_seek`), queues `Command::Seek { position_us, serial }` and returns; the worker publishes that serial as the applied epoch when it applies the seek, and `poll_video`/`poll_audio` deliver nothing while the caller's serial is ahead of the applied one - while still *draining* the queues, because the worker blocks in `send_bounded` on a full queue and only reaches its command check once there is room, so returning early would deadlock the two. A worker that cannot apply the seek still fails the session through `status()`, which the pane already renders. **Measured after: `seek` returns in 1.01 µs** with the decoder parked, and the same test finishes in 0.02 s; it also asserts no frame is delivered while the seek is pending and that the first frame after release carries `pts_us >= the target` (the per-stream skip rule). The seam gained `stuck::lock()` because two tests arm one global slot and `cargo test` runs them in parallel. `test_transport_pause_and_seek_are_reported` now waits for the reported position instead of reading it on return - the one intent-preserving test change this contract needs - and `media_pane.gd` itself is unchanged. `rust.md`'s decode model and the wiki's media-pane table describe the new contract.

Commits: f0e1ddf, e239a8e

## MEDIA-12

**A media probe leaks the FFmpeg read buffer on every open** - found 2026-11-01 by the new `media_probe` fuzz target ten seconds into its first run: a crafted 85-byte RIFF header made LeakSanitizer report 32 KiB unreachable per probe (2000 calls, 65,536,000 bytes), and a plain release build grew 6-8 KiB per open for both the crafted input and a valid WAV, measured through VmRSS over 1000 opens. Cause: `Avio` passes its own 32 KiB buffer to `avio_alloc_context`, and `avio_context_free` frees the AVIOContext but never a caller-supplied buffer (ffmpeg 9.0.2 `libavformat/aviobuf.c`), while the `Drop` comment assumed it did; `ffio_ensure_seekback` may also replace that buffer with a reallocated block, so the pointer current at drop time is the one to free. `Avio::drop` now frees it after the context. Verified: 2000 ASAN calls of the crafted input report no leak and no double-free, and 1000 plain opens hold VmRSS flat at 4744 kB (crafted) and 5776 to 5780 kB (WAV), where the same loop grew 8 MB and 6 MB before. The regression evidence is the fuzz target itself (LeakSanitizer under ASAN); no portable Rust test can assert a heap bound, so the target and its scheduled run own this check.

Commits: 39085e9

## MEDIA-13

**The media pane interleaves audio one sample at a time** - measured: `_feed_audio` (`godot/scenes/panes/media_pane.gd:518-527`) interleaves each 2048-frame stereo chunk in a GDScript loop (`buffer[f] = Vector2(data[f * channels], data[f * channels + 1])`), 84.8 us per chunk on 4.7.2 (`gdscript_probe`: 84,765 us for 1000 chunks), ~1.95 ms/s at the steady 23 chunks/s and ~678 us for an 8-chunk burst. The video half was checked and is not queued: `Image.create_from_data` measured 0.13 us per 1280x720 image (0.2 us with `get_data()` forced), `Image.set_data` 0.07 us, and the data is copy-on-write, so the remaining per-frame cost is the texture upload (not measured headless), which reuse does not remove. Fix: change `GptyMedia.poll_audio` to return a `PackedVector2Array` (mono duplicated to stereo) built in Rust, deleting the loop; `_feed_audio` pushes it directly. Tests: `test_media_pane.gd`/`test_media_backend.gd` pass, audio samples equal the current path for mono/stereo, `_feed_audio` per-chunk time down expected >=50%. Evidence: `TEMP/gdscript-opportunities.md`.

## MEDIA-14

**Narrow the Windows media build** - the `vcpkg` FFmpeg carries a wider internal codec set than the pinned Unix configure. Either pin a vcpkg baseline with a curated feature set, or build the same 9.0.2 tarball under `MSYS2`/`clang-cl`; the runtime allowlist already refuses unlisted codecs, so this is surface and size, not behavior.

## MEDIA-15

**Media hardware decode** - VAAPI/VideoToolbox/D3D11VA through FFmpeg hwaccel. The software path is deliberate for the first backend; hardware frames need a transfer step, a per-platform fallback and the same bounded-queue discipline.

## MEDIA-16

**Use `libdav1d` for AV1** - the pinned build currently uses FFmpeg's native AV1 decoder. dav1d is the faster, standard implementation (BSD; no GPL concern), so this is a build-recipe + CI change behind the same `Id::name()` allowlist, not an API change; measure first.
