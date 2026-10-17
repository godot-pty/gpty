class_name Palette
## Shared UI colors.
##
## One definition for the accents more than one surface draws with: the
## sidebar's active row and the link graph's selection ring must read as the
## same color, and a second literal would drift. Pure constants — no scene
## tree, no manager — so a canvas (or a test) can use them without dragging in
## the app's autoloads.

## The accent: active rows, selection rings, highlighted edges.
const ACCENT_COLOR := Color(0.45, 0.7, 1.0)
## The accent under the pointer.
const ACCENT_HOVER_COLOR := Color(0.6, 0.8, 1.0)
