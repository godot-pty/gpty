# Media Pane

A media pane plays one local audio or video file: video as a letterboxed surface, audio through a generated stream, with its own play, pause, seek and loop controls.

## What it is

The body is `MediaPane` (`godot/scenes/panes/media_pane.gd`); the registered type key is `media` and its label prefix is `M`. It is the eighth pane type and the only one that decodes anything: video frames arrive as textures, audio as samples, both from the pinned FFmpeg backend in the `gpty-media` crate.

A media pane is a path carrier. It holds an absolute local file path, and the path is validated at the moment it is used, not when it was stored. Nothing about a path is trusted: it may have come from a saved layout or a profile, which are files.

## When to use it

Use it to check a screen recording, watch a reference clip, or listen to a voice memo without leaving the workspace. Use the [[file-tree|File Tree]] to reach the file — activating a supported media file there opens this pane — or point the pane at a path yourself.

For still images there is no image pane; the file tree hands them to the system handler after confirmation. This pane plays containers with audio and/or video streams, not pictures.

## How to open it

| Method | Action |
|---|---|
| Sidebar | the media button |
| Palette | `new media` |
| CLI | `gpty new-pane -t media` |
| MCP | the `new-pane` tool with `type: "media"` |
| From a pane | activating a supported media file in the file tree |
| Layout/profile | a saved tile restores its file and transport settings |

A fresh pane opens empty and shows a placeholder asking for a path in Pane Settings. The file is pane state, so the CLI and API cannot name it; the file tree route passes it in the pane request. Opening the same file that an existing media pane already holds focuses that pane instead of starting a second decode — two panes on one file would double both the sound and the work.

## What it shows and how it is driven

Video is drawn into a texture with aspect-preserving fit, so a clip narrower or wider than the pane is letterboxed rather than stretched. Presentation is clocked against audio playback position when there is audio, and against a monotonic start clock otherwise, so a decoder that runs faster than real time does not play the file several times too fast.

Audio is decoded to interleaved 32-bit float and pushed into Godot's audio generator at 48 kHz stereo by default. Video and audio share one session; only the streams the pane will actually drain are opened, because an unconsumed queue is backpressure and would stall the other stream.

The transport bar appears under the content:

| Control | Effect |
|---|---|
| Play / Pause | toggles playback at the current position |
| Seek slider | drag to seek; the seek is acknowledged by the backend before playback continues |
| Time label | position and duration (`0:00 / 0:00`) |
| Loop | replays from the start at end of stream; stored with the tile |

`paneStatus` reports the pane through the shared status document: `kind` (`video` or `audio`), `file`, backend `state`, `position_us`, `duration_us`, `paused`, `loop`, `volume_db` and `muted`. A pane with no file (or no backend) reports `null` rather than disappearing from the pane list.

## Formats

The pane's table is closed. Anything outside it is refused with a message that names the supported set.

| Kind | Extensions |
|---|---|
| Video | `.mp4` `.m4v` `.mov` `.mkv` `.webm` `.avi` `.ts` `.m2ts` `.ogv` |
| Audio | `.ogg` `.oga` `.opus` `.mp3` `.wav` `.flac` `.m4a` `.aac` |

The backend decodes H.264, H.265, VP8/VP9, AV1 and Theora video. The list is an allowlist, not a sniff: the extension decides, so the same file always takes the same route and an unknown extension never reaches a decoder.

## Settings that matter

| Setting | What it changes |
|---|---|
| Name | the pane's title |
| Font size | the placeholder and status text |
| File | absolute path of the media to play |
| Volume | −40 dB to +6 dB, in 0.5 dB steps |
| Mute | silences output without changing the volume value |

Volume, mute, loop and the file path are saved with the tile. The panel re-applies its whole dictionary on every keystroke, so only a path that actually changed restarts the decode; editing the name does not interrupt the clip.

## What it does not do

It does not open remote media. A path containing `://` is refused as a remote URL, and `res://` and `user://` are refused as project schemes rather than local files. The FFmpeg build compiles no network protocols, so even a crafted stream is not a network client. It never loads a path through `ResourceLoader`, which is what would otherwise let a `.gd` or `.tscn` renamed to a media extension be loaded as code.

It also does not play playlists, burn in subtitles, or provide frame stepping; the transport is the four controls above.

## Limits and edge cases

The path is refused if it is empty, a `res://`/`user://` project scheme, or any URL containing `://`; otherwise it must be absolute, carry a known extension, and name a regular file, so a FIFO or device node cannot reach a decoder. The pane holds one session and one file. Long file names are ellipsized in the placeholder at 120 characters — the settings row still shows the full path. Closing the pane stops the decode; there is no background playback without a pane.

## Related

- [[pane]]
- [[file-tree]]
- [[code-viewer]]
- [[security-model]]
