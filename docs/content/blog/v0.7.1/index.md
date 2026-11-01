---
title: gpty v0.7.1
date: 2026-11-01
---

v0.7.1 is the trust-boundary release: the October audit's remaining findings are closed, and the
fixes a user actually feels came with them - a selection that stays on its text, a paste that cannot
close its own bracket, a pane that can no longer grow the window with an unterminated escape string,
and a media seek that no longer freezes the window.

<!--more-->

![Screenshot](/images/v0.7.1_1.png)

**A selection stays on its text.** Scrolling a pane back and pressing `Ctrl+Shift+C` used to snap the
view to the bottom, because a bare `Ctrl` counted as scrolling input. It no longer does. The selection
now follows its text through the wheel, PageUp/PageDown, a search jump and arriving output instead of
holding a fixed screen row; copy reads grid rows, so a selection scrolled out of view still copies in
full; wrapped lines copy joined instead of gaining a newline at every wrap; and a width change or an
alternate-screen switch drops the selection, which is alacritty's rule - the old highlight survived and
landed on different text.

**A paste cannot close its own bracket.** Both paste branches drop the control characters that could
end a bracketed paste early, so a clipboard holding an escape sequence can no longer submit the rest
of itself as typing. The filter is one cached PCRE2 pass: 1 MiB in 6 ms, where the per-character loop
it replaced took 34.8 s.

**An escape string cannot grow the window.** A pane printing `ESC ] 0 ;` and then an endless payload
used to sit inside the grid's parser, which buffered it without a ceiling - measured at 3.3 MB to
260 MB resident in 1 MiB steps, with no bound. The string is now closed at 64 KiB, the same bound the
line parser already applied. On Windows ConPTY consumes the string before gPTY sees a byte, so the
live smoke proves which platform the guard covers instead of claiming both.

**A window holds at most 96 live panes.** A profile with 300 tiles used to restore 300 live PTYs, and
`list-panes` then took seconds to answer. The ceiling is counted across every workspace, because a
hidden workspace's pane keeps its process and grid; past it, `new-pane` and `pane-run` answer with the
limit, and a layout restores what fits and says how many did not.

**Your secret stays out of the panes.** The GUI and the CLI now harden themselves: on Linux they set
`PR_SET_DUMPABLE 0`, which makes `/proc/<pid>/environ` unreadable to a program running in a pane; on
Windows they install a process DACL that withholds memory-read and thread-injection rights while
keeping the peer check and terminate rights the control socket needs. Reading `GPTY_SECRET` out of the
GUI's environment is what used to make the secret meaningless on both platforms.

**The vault verbs answer only for a vault you registered.** `vault search`, `vault read` and
`vault weight` serve a root the user registered by opening that vault in a Wiki pane's settings; a
refused root says so and how to fix it. A request naming any other path no longer makes the socket
index it.

**The media pane stops freezing.** A seek used to wait for the decoder's acknowledgement with a 5 s
deadline, on the Godot thread - so one slider step on a file that keeps the decoder busy froze the
whole window. It now returns as soon as the command is queued (measured at 1 µs with the decoder
parked), and the pane is told nothing from the replaced timeline is presentable until the seek is
applied. The same release bounds a pane close at 2 s when a decoder call never returns, opens media
through a verified descriptor so a swapped FIFO cannot block `open(2)`, and refuses an audio frame
that would resample past the size cap before allocating it.

**A refusal reaches you as its own sentence.** A handler's refusal now arrives in the CLI and in MCP
as the handler wrote it - `error: rpc error -32000: Pane 'x' not found` - instead of a stringified
JSON envelope, and an MCP tool that refuses is a successful response carrying `isError: true` with
that sentence. One IPC connection also serves a batch now: a client that pipelines several requests
gets one answer per request, in order, and a bad frame costs only that frame.

**A release is three downloads.** The platform archives already contain the GDExtension and the
pinned FFmpeg libraries, so publishing them again made a 36-file release page whose download count
told you nothing. A release is now the three archives plus `SHA256SUMS`, attested by the workflow that
built them.

**Release**

- Download the standalone binary from [GitHub Releases](https://github.com/godot-pty/gpty/releases/tag/v0.7.1).
- Full changelog: [Changelog](https://github.com/godot-pty/gpty/blob/main/docs/content/docs/changelog/v0.7.1.md).
- Source: [github.com/godot-pty/gpty](https://github.com/godot-pty/gpty).
