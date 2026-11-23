---
title: gpty v0.8.6
date: 2026-11-23
---

v0.8.6 is the visual identity release. The interface stops looking like a generic Godot app:
terminal effects are a closed table with an Off/Subtle/Full intensity, panes animate as they are
created, closed and swapped under one Motion setting, and a concept can cue its pane with a tint,
pulse or particle burst. Every effect is a setting, off or subtle by default, and display-only.

The vault becomes a physical 3D map you can push around, the terminal joins the chrome's light/dark
choice with imported colour schemes, the window can go translucent, and the engine's splash is
replaced by a branded launch frame. First run now teaches every shortcut, and Settings > About can
read the README and everything it links.

The renderer bake-off kept Forward+ as the default and documented Compatibility as the 2.2x-lighter
opt-in. None of this is a skin over the same app: the effects, transitions and cues share one
preference model, and every one of them can be turned off.

<!--more-->

![A fresh launch on v0.8.6](/images/v0.8.6_1.png)

**The terminal joins the chrome.** The chrome has had a light theme since v0.8.0; the terminal did
not follow it, because its palette was a single scheme. Now the terminal reads a dark and a light
scheme through the same resolution as the chrome, with an empty light slot following the dark one,
and the old `color_scheme` key migrates on load. A pane can still keep its own scheme.

Schemes themselves are importable: native JSON, Alacritty (TOML and YAML), an iTerm2 XML plist,
Base16 or a legacy 16-colour CSV, capped at 16 KiB and validated by one closed native parser. An
imported native file is copied into `user://schemes/`, so the source can move or be deleted. Eleven
schemes ship - dracula, gruvbox dark/light, nord, tokyo-night, catppuccin mocha/latte, one-light,
solarized dark/light and vivid - and colour now reaches the cells for real, including the default
foreground and background pair.

Two window-fit settings arrived with it. **Window opacity** makes the whole window genuinely
translucent: one full-screen veil samples the finished canvas and writes the setting's alpha once,
so the 70 % setting measures 0.698 instead of the 0.992 a per-surface tint produced. Where the
driver cannot make the window transparent, the row stays visible, disabled, and says why.
**Terminal padding** spends 0-24 px per side on the fit, so the row and column counts always equal
what the pane draws.

![The light chrome over four terminal panes](/images/v0.8.6_2.png)

**The vault becomes a place.** The wiki graph is now a `SubViewport` holding a rigid body per note
and a spring per drawn edge. Drag a node and it pushes its neighbours; release it and the map
settles, rewriting the incident rest lengths. Positions persist in the pane's layout state, the
simulation freezes when settled or hidden, and the graph data, link resolution and hit-testing stay
in one owner. Halos, depth fog, a moving-only dust field and a vignette do the atmosphere; glow is
Forward+ only.

Planar remains the fallback. Auto mode now resolves from the adapter rather than the renderer: the
orbital map on any hardware adapter, Compatibility included, and the planar canvas only on a
software rasterizer. That supersedes v0.8.5's "Compatibility resolves to planar" rule, and an
explicit 3D or 2D choice still wins everywhere.

![The orbital vault graph](/images/v0.8.6_3.png)

**Effects you can turn down.** `Settings -> Appearance -> Effects` is a closed table: CRT scanlines
(static, with a scanline period computed from the pane's own height and cell height) and film grain
(a half-resolution buffer at 30 Hz). Off is the default, Subtle halves the amplitude, and only those
two shaders can run - no profile, settings file or plugin can name another. A pane paints its ground
through one effect layer, so text, selection, inverse cells and ANSI backgrounds stay opaque, and a
static effect is not evaluated per frame.

The same tab owns Motion: Off draws every change in one frame, Subtle eases without overshoot, and
Full allows the animation's declared overshoot capped at 3 %. The registry decides everything - each
entry declares the transitions it serves, the channels it touches and its property schema - so
slide, pop and crossfade appear in the pickers from their table entry alone. A create reserves its
final rect before it animates, so no sibling moves.

Reactive environments map a concept to a cue: Off, Tint, Pulse or Particles, at most eight rules and
none by default. The existing concept drain fires it for a routed capture and for a notify-only
notice. A pane cues at most once per 334 ms, a hidden pane never cues, and nothing is acknowledged,
flushed or published back into the engine - the cue is display-only.

![The Motion and Effects sections](/images/v0.8.6_4.png)

![A pinned Tint cue on the pane that fired the concept](/images/v0.8.6_5.png)

**A launch frame, and a renderer decision.** The engine's Godot logo on grey is gone.
`godot/assets/boot_splash.png` is a 3840x2160 frame: the icon's line art, a 640 px mark and a 240 px
wordmark over an accent glow on the dark surface `#202128`. The window's clear colour is pinned to
the same colour, so a letterbox or crop edge is seamless.

The bake-off ran the shipped v0.8.5 build on both renderers. Forward+ is 667 MB warm with one pane (669 with
eight, 1083 on a first launch); Compatibility is 310 (305 with eight, 363 on a first launch), 2.2x
lighter warm and 3x lighter on a first launch. Mobile was only 11 % below Forward+ and was rejected.
Repaint showed no material penalty on either renderer, so the decision is about what the app is
made of: the orbital graph's bloom and the visual identity need Forward+. Forward+ stays the
default, pinned explicitly in `project.godot`; `--rendering-driver opengl3` is the documented opt-in.
The 4K effect bench still cannot isolate a shader, so that measurement stays in v0.9.

**First run, and About.** The empty workspace is a Getting Started guide: a living keycap that cycles
the four spawn chords, an Open a Terminal action, and all 23 registered bindings as grouped cards.
The hero keycap takes the keyboard on a zero-pane first run. `Settings -> About` is now a
documentation viewer over a generated bundle of the Markdown reachable from `README.md` - the root
guides, the roadmap, the changelog and the agents pages - with internal links that stay inside the
bundle and a Back button that always reaches the README.

**Release**

- Download the standalone builds from [GitHub Releases](https://github.com/godot-pty/gpty/releases/tag/v0.8.6).
- Full changelog: [Changelog](https://github.com/godot-pty/gpty/blob/main/docs/content/docs/changelog/v0.8.6.md).
- Source: [github.com/godot-pty/gpty](https://github.com/godot-pty/gpty).
