---
title: gpty v0.7.0
date: 2026-10-20
---

v0.7.0 puts local media in the grid. A new `media` pane plays audio and video from disk through a
pinned, minimal FFmpeg build, with transport controls, pane status, and the same closed path and
codec tables as every other untrusted input gPTY accepts. The release also makes the first
keystroke land at launch, asks before a close stops running work, and moves the CLI to a
single-threaded runtime.

<!--more-->

![gPTY v0.7.0](/images/v0.7.0_1.png)

## A media pane, not a browser

The pane takes one absolute path to a regular local file, checked against the closed `MediaFiles`
table before anything opens. Remote URLs, FIFOs, devices and Godot project schemes are refused with
an in-pane explanation, and the path never reaches `ResourceLoader`, so a file supplied by a layout
or profile cannot smuggle a script in behind a media extension. Reopening the same file focuses the
pane that already plays it, and a restored tile remembers its path.

The Rust backend covers the containers MP4, MOV, MKV, WebM, OGG, WAV, FLAC, MP3, AAC, AVI and
MPEG-TS; H.264, HEVC, VP8, VP9, AV1 and Theora video; and MP3, FLAC, Vorbis, Opus, AAC, ALAC, AC-3
and PCM audio. It is one decoder path for both halves: video arrives as packed RGBA8 frames, audio
as interleaved f32 at the requested rate and channel count.

## Pinned, bounded, and honest about it

`gpty-media` links a pinned FFmpeg 9.0.2 built shared and minimal with `--disable-everything
--disable-network`; only the components in `components.txt` are compiled in, and the runtime
allowlist refuses anything unlisted. Each session owns one worker thread, a bounded packet queue and
bounded output queues: the pane polls, a full queue blocks only that decoder, and a seek is
acknowledged by the worker so pre-target frames are dropped rather than delivered.

The decoders are in-process C code. There is no sandbox claim: the defense is the closed path,
demuxer and codec tables, size and queue caps, and the minimal build, and SECURITY.md says exactly
that. Hardware decode is deliberately off for this first backend.

## Transport that stays in sync

Play/Pause, a seek slider with elapsed and total time, and Loop sit under the surface; volume and
mute are pane settings saved with the tile, and `paneStatus` reports the media state alongside a
terminal's process and grid document. Pause freezes the media clock and the generator; a seek resets
the frame, audio and clock state before the new position plays; Loop restarts a finished file from
zero.

Audio is pushed into an `AudioStreamGenerator` at 48 kHz stereo, and video presentation follows the
audio clock when audio is running (a monotonic clock otherwise). The video backlog is bounded at
four frames and filled only while it has room, so a decoder that finishes a clip in milliseconds
cannot discard frames that are already due; a stream whose timeline does not start at zero begins
its clock on the first frame's own PTS.

![The media pane playing the test pattern](/images/v0.7.0_2.png)

## Nothing extra to install

Release archives carry the matching FFmpeg libraries beside the GDExtension for Linux and Windows,
and a universal, ad-hoc-signed set inside the macOS app bundle. The LGPLv3/LGPLv2.1 texts and the
component list travel with them, and the AUR recipe installs the same layout. A locally extracted
Linux bundle starts with `LD_LIBRARY_PATH` unset.

## Also in this release

- **The first keystroke reaches the shell.** A fresh workspace now activates its first terminal at
  launch, so typing works without clicking a pane first.
- **Closing asks before stopping work.** A pane, workspace, profile switch or quit that would kill a
  running command raises one confirmation naming the busy panes; an idle shell closes silently.
- **The CLI runs on a current-thread runtime.** Each command is one request in a process that exits
  immediately, so the worker pool only added startup cost and an exit race; 300 `gpty version` runs
  went from 1.04 s to 0.60 s on the development machine.
- **Media and graph fixes.** Seeking no longer fights the audio generator, fast decoders keep the
  frames that are due, and the vault graph no longer keys its edges with a NUL character Godot
  strings cannot hold.

**Release**

- Download the standalone binary from [GitHub Releases](https://github.com/godot-pty/gpty/releases/tag/v0.7.0).
- Full changelog: [Changelog](https://github.com/godot-pty/gpty/blob/main/docs/content/docs/changelog/v0.7.0.md).
- Source: [github.com/godot-pty/gpty](https://github.com/godot-pty/gpty).
