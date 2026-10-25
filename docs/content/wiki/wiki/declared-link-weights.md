# Declared Link Weights

A declared weight is a number you author for one pair of notes, overriding the mention count the [[link-graph|link graph]] measured. It is curation, and it is display-only: it changes how strongly a relationship is drawn, never what the app does.

## Measured versus authored

The index counts mentions. That number is honest and often misleading: two notes can be deeply related and name each other once, while one note can name-drop another ten times and share nothing of substance. The measured count is also not yours to argue with — it is a fact about the text.

So there are two layers over the same edge. The measured one is the `count` in the index. The authored one is a declaration you make, from 1 to 100, for one directed pair `(src, target)`. When a declaration exists it is the edge's display weight; when it does not, the count is. Neither layer changes the count itself, and clearing a declaration simply returns the edge to what the text says.

## Where it lives, and who owns it

Declarations live in `user://link_weights.json`, keyed by vault, then source note, then target note:

```
{"vaults": {"/abs/vault": {"note.md": {"other.md": 10}}}}
```

That file is deliberately not `vaults.db`. The index is a derived cache that a schema bump may rebuild from scratch; authored work must survive a rebuild. The weights file is user-owned, hand-editable, and validated on load: the file is a boundary like every other store, so a malformed entry loses itself rather than the file, and paths and weights outside the vocabulary are dropped.

The store belongs to the running GUI. The graph canvas writes through it, and the CLI's write is routed to the GUI as well — a `gpty vault weight` call needs a running gPTY, and there is no independent copy of the file for a headless process to edit. [[cli|CLI]] describes the client's general posture.

## What a weight changes

A declared weight feeds exactly three things:

| Effect | Detail |
|---|---|
| edge thickness | logarithmic and clamped, so 100 is emphatic but not a wall |
| layout stiffness | the Relayout springs use the same logarithm |
| link-panel order | a declared pair sorts above measured ones in "Links to" / "Linked from" |

That last one matters more than it sounds. The link panel shows a bounded number of rows per section; ordering by declaration lets a curated relationship surface from past the cap, and the footer still counts everything the cap excluded.

## What it never does

A declaration is not consent, not navigation, and not data about the vault:

- It never hides an edge. Every edge the index found is still drawn.
- It never gates a click. A declared or undeclared edge opens the same note.
- It never writes to the vault. No note text changes.
- It never counts as a trust decision, a spawn permission, or an instruction to an agent.
- It never survives as a fact about the notes; delete the JSON and the graph is exactly the mentioned structure again.

The pause is worth stating plainly: the strongest thing a weight can do is make a line thicker and pull two nodes closer on a canvas you are looking at.

## Setting one

In the graph, right-click an edge and choose Set declared weight… then pick a number; the same menu clears it. A ghost edge is not offered, because a declaration names two notes. The prompt says what the value affects, so the display-only boundary is visible at the moment of authoring. Setting a weight re-applies the canvas immediately but does not reshuffle it; Relayout applies the new springs.

For an agent or a script:

```bash
gpty vault weight ~/notes wiki/vault.md wiki/wikilinks.md --weight 80
gpty vault weight ~/notes wiki/vault.md wiki/wikilinks.md --clear
```

The MCP tool is `vault-weight`, with the same parameters. A clear of an absent declaration succeeds, so "no declaration" can be stated idempotently. Note that the canvas's human control writes both directions of a drawn pair in one write, while the CLI writes one directed number — the file's shape stays directed, so an agent can express exactly one endpoint.

## Rename and prune

A declaration is keyed by vault-relative note paths, so a rename would strand every entry naming the old path. The pane re-keys both endpoints immediately after a successful rename: declarations on the note, pointing at it, or naming it on both sides move to the new path in one write, a stale row already stored under the destination loses to the moved one, and unrelated declarations are untouched. This runs before any question about rewriting references, because it does not depend on that answer.

Pruning is lazier by design. When the pane shows a *complete* graph, declarations whose endpoints are no longer notes in the vault are dropped, so the file does not accumulate names forever. A truncated graph does not prune: the edges it does not name are still real, and deleting their authored weights would be unrecoverable.

## Related

- [[link-graph]]
- [[vault]]
- [[wikilinks]]
- [[cli]]
- [[wiki-pane]]
