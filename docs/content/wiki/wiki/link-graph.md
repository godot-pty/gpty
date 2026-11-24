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

There is no `.canvas` and no second format. Open the graph and it queries the index; open it again after an edit and it queries again, because every mutation — a save, a create, a rename, a delete, a reference rewrite — re-indexes before returning. One source of truth means the graph cannot describe a vault that no longer exists.

The arrangement is not part of the vault either. It rides the pane's own layout state as a bounded `graph_positions` block (a note that has left the vault is ignored), so a restored workspace reopens the map where you left it while a new pane starts from the deterministic layout. The live view keeps the positions of notes it already placed and only seeds new ones, so a re-query mid-session does not undo your drag; the vault file set is untouched by any of it.

## The layout is deterministic

The same nodes and edges always lay out the same way. A sunflower seed (no random source) places the nodes, then a relaxation pass runs a bounded number of iterations, with each pair's spring strength derived from its display weight through the same logarithm used for thickness — so a chatty note cannot dominate the arrangement any more than it can dominate the line widths. Node radius follows degree, edge thickness is logarithmic and clamped to 1–3 px, and labels are drawn for every node only while the graph is zoomed in enough and small enough to read (up to 120 nodes); the hovered and selected nodes always get one.

Relayout runs the deterministic pass again. It is also the moment a newly declared weight changes the arrangement: setting a weight re-applies the display values without reshuffling the canvas, and Relayout applies it to the springs.

## Using it

A new wiki pane opens on the graph, and opening it re-reads the index. The list shows **Graph**, the note editor shows both **Notes** and **Graph**, and the graph shows **Notes**, which returns to the list. The query, the model and the layout run on a worker thread, so opening a large vault's graph does not freeze the window: the canvas appears on the frame the build lands. The interface is small and stated on screen:

- drag the background to orbit the orbital map; **Shift**-drag or middle-drag pans, and dragging a node moves it
- the wheel (or `+`/`-`) zooms at the pointer; **Shift**+wheel, **Page Up** and **Page Down** travel through depth — the perspective dolly that moves the map's near and far layers apart, so the z layers are reachable from any orbit angle
- **Planar** / **Orbital** switches the presentation: the orbital map is the 3D physics view, the planar canvas is the flat fallback; one button, and its text names the other presentation
- **Relayout** resets the deterministic arrangement and fits it in the view, so it is also how a lost camera comes home
- Arrows toggles direction drawing; a mutual pair is drawn double-headed
- the pane's **Link map theme** setting (Pane Settings) paints the map with the **Default** or **Planetary** theme; a non-default theme is named in the status line

Clicking a note node opens it, behind the same Save / Discard / Cancel ask that leaving a note always makes — the graph can sit over a dirty buffer, and a click is what would replace it. Clicking a ghost runs the same resolution a mention does: a missing target offers create-from-link, while an ambiguous stem reports its candidates and does nothing, because either choice would be a guess.

Right-clicking an edge offers to set or clear a declared weight. That control is described in [[declared-link-weights|Declared Link Weights]]; the graph itself only draws what the store answers.

## Themes

The graph's painting is a closed table of its own, separate from the chrome's palette: `GraphTheme` owns every colour and effect the two presentations draw, and a theme carries a complete dark and light set. **Default** derives from the app palette and reproduces the shipped look. **Planetary** is the first authored theme: notes become lit worlds with a deterministic hue each, the busiest notes carry tilted rings, a starfield and drifting dust sit behind them, and selection and related edges turn gold; in the light appearance it becomes a daylight-orbit palette instead. Glow, fog, the halo and the vignette are theme values too.

The theme is per pane, like **Link map**: set **Link map theme** in Pane Settings and both presentations repaint immediately without moving a node. A theme never changes the graph's data, the layout's determinism, which edges exist, or what a click can reach.

## What it is not

The graph is not an editor, not a validator, and not a dependency map. It shows mention structure only: two notes that are deeply related but name each other once will sit far apart, which is exactly why a weight can be declared. It also cannot show what the index refused to resolve — a ghost is a target, not a note, and it disappears the moment a note resolves it.

## Related

- [[vault]]
- [[wikilinks]]
- [[declared-link-weights]]
- [[wiki-pane]]
