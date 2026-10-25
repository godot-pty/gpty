# Link Graph

The link graph is a canvas view of how the notes in a [[vault|vault]] name each other. It is generated from the same index the note list and search use, so it is a picture of the stored [[wikilinks|wikilinks]], not a second document you maintain.

## Nodes, ghosts, and edges

The graph is read from `vaults.db` each time you open it; nothing is stored and no note is re-parsed for the drawing.

| Element | What it is |
|---|---|
| node | one indexed note; its id is the vault-relative path and its label the indexed title |
| ghost | one node per distinct unresolved target, named `ghost:<target>` |
| edge | one ordered `(src, dst)` pair, with a count of occurrences |
| `truncated` | a cap cut the answer short |

Edges aggregate: two notes that mention each other several times do not produce a crowd of lines. The index answers one row per ordered pair with its mention count, resolved rows first and unresolved ones after, each ordered by count then name. The canvas then draws each note pair once, adding both directions, so a mutual pair is a single edge — with direction shown when Arrows is on. A ghost edge is an edge, not a separate class of anything: it is the same mention with nothing on the other end.

Caps bound what a drawing can reasonably be. A canvas past 10,000 edges in one class, or 2,000 ghosts, is a hairball and also a large answer to move across the bridge. `truncated` means a cap cut the answer, so the drawing is real but partial. The status line says it plainly: notes, links, missing targets, declared weights, and `truncated`.

## Why there is no graph file

There is no `.canvas`, no saved coordinates, and no second format. Open the graph and it queries the index; open it again after an edit and it queries again, because every mutation — a save, a create, a rename, a delete, a reference rewrite — re-indexes before returning. One source of truth means the graph cannot describe a vault that no longer exists.

The cost of that choice is that geometry is session state. Positions live in the canvas view only, so the arrangement is not shared, not committed, and not part of the vault. That is also what lets a drag survive a re-query: the view keeps the positions of nodes it already placed and only seeds new ones, so opening the graph again mid-session does not undo your arrangement. A fresh session starts from the deterministic layout.

## The layout is deterministic

The same nodes and edges always lay out the same way. A sunflower seed (no random source) places the nodes, then a relaxation pass runs a bounded number of iterations, with each pair's spring strength derived from its display weight through the same logarithm used for thickness — so a chatty note cannot dominate the arrangement any more than it can dominate the line widths. Node radius follows degree, edge thickness is logarithmic and clamped to 1–3 px, and labels are drawn for every node only while the graph is zoomed in enough and small enough to read (up to 120 nodes); the hovered and selected nodes always get one.

Relayout runs the deterministic pass again. It is also the moment a newly declared weight changes the arrangement: setting a weight re-applies the display values without reshuffling the canvas, and Relayout applies it to the springs.

## Using it

The Graph button on the notes list opens it and re-reads the index. The interface is small and stated on screen:

- drag the background to pan, wheel to zoom, drag a node to move it
- Fit frames the whole graph
- Arrows toggles direction drawing; a mutual pair is drawn double-headed
- Relayout restores the computed arrangement

Clicking a note node opens it, behind the same Save / Discard / Cancel ask that leaving a note always makes — a click can replace an unsaved buffer, so the graph cannot open over one. Clicking a ghost runs the same resolution a mention does: a missing target offers create-from-link, while an ambiguous stem reports its candidates and does nothing, because either choice would be a guess.

Right-clicking an edge offers to set or clear a declared weight. That control is described in [[declared-link-weights|Declared Link Weights]]; the graph itself only draws what the store answers.

## What it is not

The graph is not an editor, not a validator, and not a dependency map. It shows mention structure only: two notes that are deeply related but name each other once will sit far apart, which is exactly why a weight can be declared. It also cannot show what the index refused to resolve — a ghost is a target, not a note, and it disappears the moment a note resolves it.

## Related

- [[vault]]
- [[wikilinks]]
- [[declared-link-weights]]
- [[wiki-pane]]
