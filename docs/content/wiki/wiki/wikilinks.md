# Wikilinks

A wikilink is a note naming another note in double square brackets. It is the only cross-note link syntax in a [[vault|vault]], and it is stored as a real edge, so the same text that navigates the preview also draws the [[link-graph|link graph]] and answers backlinks.

## The three forms

```
[[target]]
[[target|alias]]
[[target#heading]]
```

The first is a plain link, and the target is its own label. The second keeps the same edge but displays the alias instead. The third keeps the same edge and lands on a heading inside the target.

Only the target forms the edge. An alias is display text and never part of the edge, and a fragment says where inside the resolved note to scroll, never which note to open. Both are re-read from the line for rendering, so the stored edge cannot disagree with what the preview shows.

A target is resolved one of two ways. If it contains `/`, it is a path relative to the vault root, with or without the `.md` extension (`notes/vault` and `notes/vault.md` both name the same file). Otherwise it is a file stem, so two notes in different folders can share a stem — and that is the source of the ambiguity rule below.

## How a target resolves

Resolution runs in two stages, and the second only happens when the first finds nothing:

| Stage | Rule |
|---|---|
| Exact | the path, or the exact stem, matched as written |
| Case-insensitive | a *unique* case-insensitive match on the same key |

More than one match at either stage is ambiguous. An ambiguous target is reported with its candidate paths and is never chosen — picking one would be a guess, and the next unrelated file could change the answer. The link panel shows it as `ambiguous:` with the candidates and does not make it clickable. A target nothing matches is "missing" and stays unresolved until a note appears that resolves it.

Resolution is the index's own rule, used by the preview, the link panel, and the graph alike, so following a mention and counting an edge can never disagree.

## One row per occurrence

Every occurrence is its own stored row, with the line it was written on. A note that says the same target three times has three rows; each is a mention you can navigate to, and the graph counts three. Backlinks are the same rows read in reverse: the notes that mention this one are a query over the same table, not a second authored thing, so a backlink cannot fall out of date relative to its outgoing mention.

The link panel under the open note shows both directions: "Links to" lists the note's mentions with line numbers, and "Linked from" lists the notes that name it. A resolved outgoing row opens its target in place, and a backlink row opens the linking note at the mention's line, derived from the nearest heading above it. Following a link goes through the same leave guard as leaving the note, so a dirty buffer is never replaced silently.

## What stays literal

A note has to be able to document this syntax without linking to anything. Four things are therefore never parsed as links:

- fenced code blocks (three or more backticks or tildes, closed by the same character at the same length or longer)
- inline code spans (a backtick run closed by a run of the same length)
- an opener escaped with a backslash
- a target longer than 1,024 bytes

That is why the examples in this note sit inside code spans and fences. Outside one, the same text is a live mention — and an unresolved one becomes a ghost node in the graph.

Parsing is capped at 512 occurrences per note. The cap exists to bound what one note can write: at the 2,000-note walk cap a single pathological note would otherwise add a million rows. A note that mentions a target fifty times is a list, not fifty distinct relationships, though each mention still counts until the cap.

## Following, creating, renaming

Following a mention is in-place navigation, not a history stack: the notes list is the way back. A heading fragment lands on that heading after the note renders — exact text first, then case-insensitive — with anchors read only from source outside front matter and fenced code, so a note documenting Markdown grows no anchors.

An unresolved target offers create-from-link: the pane asks for a path pre-filled with the missing name (and `.md` appended when the last path component has no extension) and creates exactly the note you confirm. An ambiguous stem gets no offer, because creating either candidate would be a guess.

Renaming a note offers a second, separate step: "N mention(s) in M note(s) still name old-name — update them?" The preview and the write use the vault as it stands after the move, so only occurrences that resolved to the old name are respelled. Mentions of a stem two notes shared were ambiguous, so they stay untouched. An alias and a `#fragment` survive, line endings and every other byte are preserved, and fenced code, code spans, and escaped openers are not link occurrences and are not edited. The renamed note itself joins the pass only when its editor buffer is clean, because a dirty buffer must never be written under.

## Related

- [[vault]]
- [[link-graph]]
- [[note-editor]]
- [[declared-link-weights]]
- [[wiki-pane]]
