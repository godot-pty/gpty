# Concept Recipes

A concept is a named regex over terminal output plus a decision about what to do with the matching lines. These are four working rules you can observe or build, with the parts that bite.

## The mental model

One rule is a chain: a trigger pattern matched against one line of terminal output, zero or more conditions that must also match that same line, and an action that names a receiving pane type. The trigger fires, the rule captures raw bytes until its timeout window ends or the next keystroke arrives, and the captured text is handed to a pane that accepts content.

Two properties matter more than the fields:

- A concept never executes anything. There is no command field and no write to a PTY. It can only capture display text and route it.
- Only two pane types accept routed content: the Code Viewer and the Inspector. The target picker is built from that list, so a rule cannot aim anywhere else.

`gpty concept list` prints every concept with its enabled state, and `gpty concept toggle <name>` is the API for flipping one. The visual editor lives in Settings → Concepts: a canvas where each rule is trigger → condition → action and the vertical order is priority.

## Before any recipe

Open the receiving pane first, or the capture has nowhere to land. A route with no receiver at the far end produces a toast naming the concept and the missing target type, and the text stays in the terminal. Also run `gpty concept list` once so you know the exact rule names.

## Recipe 1 — `cat` into the Code Viewer

The one rule that ships enabled.

1. Open a Code Viewer pane with `Ctrl+Shift+D`.
2. In a terminal pane, run `cat Cargo.toml`.
3. Watch the Code Viewer receive the file's text as a capture.

The trigger is `(?:^|[$#>]\s)\bcat\s+\S`, an `until_stop` capture with a 300 ms window that starts when the trigger matches, plus stop-on-input. In practice: the file prints in the terminal, the capture ends a third of a second later (or sooner if you type), and the viewer shows it as content you can scroll without the shell prompt mixed in. A file that takes longer than the window to print is cut, so raise the timeout for large files.

Expected result: the viewer fills with the file, and the terminal still has the original output.

If nothing arrives, check `gpty concept list` — the rule may be off — and check that a Code Viewer pane is actually open in this workspace.

## Recipe 2 — compiler errors into the Inspector

Off by default, and gated on the Inspector's own consent.

1. Open an Inspector pane with `Ctrl+Shift+O`.
2. In the Inspector's pane settings, enable `Accept terminal concept captures (opt-in)`. The Inspector does not follow the terminal conversation on its own; this is what allows captured output to leave the terminal pane.
3. Turn the rule on: `gpty concept toggle cargo_check`.
4. In a terminal, run `cargo check` in a project with an error.

The trigger is `(?:^|[$#>]\s)\bcargo\s+(?:check|test|build)\b` with a 2000 ms window — longer than `cat`'s, because a compile run is chatty and you do not want the capture cut in half.

Expected result: the Inspector receives the compiler output as context for a question you then ask it.

If it does not work: the Inspector is private and read-only by design, so a disabled opt-in means the capture is silently dropped at the receiver, not routed somewhere else. The Inspector also runs without tools, so it can explain an error but cannot fix the file for you.

## Recipe 3 — `git diff` into the Code Viewer

Off by default; the useful default for review work.

1. Open a Code Viewer pane.
2. Run `gpty concept toggle git_diff`.
3. Run `git diff` in a terminal pane.

Trigger `(?:^|[$#>]\s)\bgit\s+diff`, `until_stop`, 500 ms. The receiver gets the diff as plain text, ANSI escapes stripped; the viewer is the place to read it at full width instead of in an 80-column terminal.

Expected result: the diff appears in the viewer while the terminal keeps its copy.

If the capture is truncated, the diff took longer than the 500 ms window to print — a pager or a slow filesystem can do that. Raise the timeout in the editor rather than shortening the command.

## Recipe 4 — a notify-only rule

Some signals are worth announcing and not worth capturing. Add a rule in Settings → Concepts with Add Trigger, Add Condition (if you need one) and Add Action, set the action's mode to Notify only, then Save.

1. Open the concept editor and add a trigger with the pattern `\btest result: ok\b`, named `tests_done`.
2. Add an action node, set mode to Notify only, and connect the trigger's output to it.
3. Save.
4. Run your test suite in a terminal and subscribe to the event socket, or watch a tool that does; the pane shows no notice of its own.

The saved rule is one entry shaped like this — no target, no stop settings, because there is nothing to route and nothing to capture:

```json
{
  "name": "tests_done",
  "trigger": "\\btest result: ok\\b",
  "enabled": true,
  "capture_mode": "single_line"
}
```

Notify-only is the `single_line` capture mode: it publishes a notice naming the rule and its source pane, captures no bytes, and delivers nothing to a pane. The matched line is deliberately not published — the event carries metadata only.

Expected result: a `concept.matched` event when the line matches, carrying the rule name and source pane; nothing is captured, nothing appears in a receiver pane, and the matched line is not published. If the rule fires constantly, the pattern is too broad — `result: ok` alone would match a line that merely mentions it. Tighten it with an anchor or a condition rather than turning the rule off.

## When a recipe goes wrong

| Symptom | Cause |
|---|---|
| Toast about a missing pane | No open pane of the action's target type |
| Capture ends mid-output | Silence timeout reached during a pause |
| Rule never fires | Pattern dialect: Rust `regex`, no backreferences or lookaround |
| Rule fires on prose in a transcript | Trigger matches any line, not just the prompt line |

The prompt-anchored prefix `(?:^|[$#>]\s)` in the shipped rules is there for the last problem: it keeps a rule from firing on a line of documentation that happens to contain the word `git diff`, or on an agent's own narration of a command it is about to run.

## Related

- [[concepts]]
- [[capture]]
- [[inspector]]
- [[code-viewer]]
- [[gpty|gPTY]]
