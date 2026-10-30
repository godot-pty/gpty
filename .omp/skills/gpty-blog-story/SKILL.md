---
name: gpty-blog-story
description: "Write a non-release gpty blog post in the house style: a hook that stands alone before the more-marker, per-bug sections with measured evidence and commit citations, what-changed/checked/still-missing close, image and shortcode rules, docs-check gate. Use when asked to write up a fix, an investigation, or a measurement."
---

# gpty blog story

Non-release posts under `docs/content/blog/<slug>/index.md`: a bug that was fixed, an investigation that concluded, a measurement that changed a decision. Release posts (`gpty vX.Y.Z`) are `skill://release` step 6; wiki notes are `skill://gpty-wiki`.

## Read the two most recent stories first

`terminal-selection-fixes` and `ceiling-cache-and-a-silent-terminal` are the house style. Voice: first-person plural, past tense, evidence-first, no marketing adjectives. Headings are claims ("The shortcut that went to the bottom"), never labels ("Introduction", "Background"). Match their density; do not copy their phrasing.

## Front matter

Only `title` and `date`. Slug is the kebab-case of the title's claim. A future `date` hides the post from the built site, which is the only way to schedule one.

## Shape

1. **Hook, 2–4 sentences, before the more-marker** (`<!--more-->`) — what changed, why it mattered, what it cost. This is all the list page shows, so it must stand alone.
2. A reproduction paragraph: exact build and steps ("On v0.7.0: scroll a pane back, drag-select a line…"). Concrete beats general.
3. One `##` per bug or thread; `###` for a sub-story — both existing posts use a subsection for "why it looked fixed once already", which is the most useful part of that kind of post.
4. `## What it does now` — the behaviour after the fix, including what was deliberately not done.
5. `## How it was checked` — tests and measurements by name.
6. `## Still missing` when something is deferred; link the roadmap row by URL.
7. Close with `Source: [github.com/godot-pty/gpty](https://github.com/godot-pty/gpty).` plus what the changelog will say, when the fix ships later.

## Evidence rules

- Every number measured, with the build or machine when it matters. "Faster" without a number does not ship.
- Every causal claim names the seam: file, function, commit hash (`git log -S` for when a line arrived).
- Never claim a fix ships in a release that is not tagged; "will ship in the next release" is the honest form.
- No invented narrative: if the cause was boring, write the boring cause.

## Images and video

- Story posts have been text-only. Add a capture only when it explains something prose cannot; capture it with `skill://gpty-ui-review` and reference it as `![…](/images/<file>.png)` — `docs-check` fails when the file is missing under `docs/static/images/`.
- Clips go through the shortcode because raw HTML is disabled in Markdown: `{{< video "demo-hero" >}}` plays `docs/static/images/demo-hero.{webm,mp4}`.
- Never put an image inside a table row (`docs-check` rejects it).

## Verify

`python3 scripts/docs-check` — relative links, `#anchors`, and `/images/…` existence. Then reread the intro on its own: the hook must make sense with nothing after it, because that is all the list page renders.

## Don't

- Don't restate the changelog; that is the release's job.
- Don't add tags, categories or weights: the section sorts by `date` and reads nothing else.
- Don't turn the post into an announcement of intent; it reports work that was done.

## Maintenance

- The two exemplar slugs age. If newer stories exist, read the newest two instead: the structure below is the check, the voice is whatever the latest posts do.
- `docs-check` validates links and images, not structure — nothing fails if the hook only makes sense after reading the body.
- Confirm `docs/layouts/shortcodes/video.html` still exists before relying on the clip shortcode.
