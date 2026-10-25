# Capture

Capture is the state machine that runs between a concept's trigger and the pane that receives the output. It answers one question at a time: which bytes belong to the terminal grid, and which belong to the block being handed to another pane.

## Starting a capture

A concept triggers on a line. That line has already been consumed by the emulator, so it reaches the grid normally — you still see the command you typed. From the next chunk of output onward the terminal enters capture mode and stops feeding bytes to the grid.

That is why the terminal appears to freeze on the trigger line for the duration of a capture: the output is being held, not lost. A capture is not a filter that copies output; it withholds it.

## Why raw bytes

The buffer holds the raw byte stream, not plain-text lines. Two consumers need different things from it:

- The receiver pane gets plain-text lines, parsed from the buffered bytes with ANSI escape sequences stripped, because it is a viewer for the content.
- The terminal gets the original bytes back if there is no receiver. Replaying text would lose colours, cursor movement, and the exact layout of a diff or a table.

Keeping the bytes is what makes the fallback safe: a capture that cannot be routed can be replayed into the grid exactly as it would have arrived, as if the concept had never fired.

## Stopping

A capture ends at the first of these:

| Stop | Detail |
|---|---|
| Timeout | The concept's `stop_timeout_ms` elapses (300 ms for `cat`, 500 ms for `git diff`, 2,000 ms for `cargo check`) |
| User input | Typing stops the capture when the concept has `stop_on_input`; resizes and internal capture commands never stop it |
| Byte cap | 4 MiB of buffered output |
| Pane teardown | Closing the source pane finalizes what is in flight |

The timeout is the concept's own window and it starts when the trigger matches, which is why a rule for a long build carries a longer value than a rule for `cat`. The byte cap bounds memory when a concept matches a flood.

When a capture finalizes it is assigned an id, its plain-text lines are extracted, and the event is queued for the GUI. Queues hold at most 64 captures and drop the oldest: a stalled GUI must not grow without bound.

## Routing

The GUI drains each pane's capture queue every frame and offers the event to the panes in its workspace. The first pane whose type matches the action's target — and that accepts routed content — receives it.

The Inspector is a receiver only when its `accept_concept_captures` option is on. That pane sends what it is given to its own model backend, so captured terminal output leaving the pane is a deliberate choice the user makes.

Two outcomes follow:

| Outcome | What happens |
|---|---|
| Routed | The sender acknowledges the capture. The buffered bytes are discarded, except the tail after the last newline: the shell prompt was never emitted as a line, so it is replayed after a newline to put it back on the grid. |
| No receiver | The sender flushes the capture. Every raw byte is replayed into the grid and the parsed lines are stored to scrollback and history, exactly as if no concept had matched. A toast names the target pane type that was missing. |

A capture still in flight when its pane is torn down is finalized into a workspace-level orphan queue. Routing from there works the same way, with one difference: the source grid is gone, so a miss can only be reported, not replayed.

## Notify-only captures

`single_line` is not a capture in the buffering sense. The matching line is turned into a notice — concept name, source pane — and nothing else. No output is held, no pane is offered content, and the terminal never freezes. Notices are bounded at 64 per pane, oldest dropped, and forwarded to the event socket so a subscriber learns the trigger fired without receiving any of the text.

## Edge cases worth knowing

Concepts are not matched against alternate-screen output at all. While a capture is active, bytes printed in the 750 ms after a resize are dropped rather than buffered: they are the child repainting a screen the grid never received, and buffering them would put a duplicate prompt into the routed block. Lines longer than 16 KiB are never matched, though the grid and history still receive them. No second capture starts while one is active, so a command whose output happens to match another trigger does not nest.

## Related

- [[concepts]]
- [[gpty]]
- [[terminal-grid]]
- [[code-viewer]]
- [[inspector]]
