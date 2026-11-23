---
title: The Windows fallback was already there
date: 2026-11-23
---

The v0.8.6 queue said the Windows build had no renderer fallback above native OpenGL 3. It had one: Godot 4.7.2's official Windows template statically links ANGLE, compiles D3D12 against the system runtime, and the engine's fallback settings were already on. What was missing was proof — no Windows job had ever launched a window and read the renderer line. This is the investigation, the primitives behind Godot's renderer choice, and the recapture that followed.

<!--more-->

On the 0.8.5 tree, `godot/export_presets.cfg`'s Windows preset set `application/export_angle=0` and `application/export_d3d12=0`, and `windows-smoke` ran GUT and the pane-API smoke with `--headless`. Reproduce the old assumption by reading the preset alone. Reproduce the proof with `python scripts/smoke_pane_api.py --renderer-smoke d3d12 opengl3_angle`, which boots the app without `--headless`, lets it render 180 frames, and parses the startup `[renderer]` line.

## The flag that only copies files

Godot's Windows exporter does not enable a backend. `application/export_angle` and `application/export_d3d12` are integer enums — Auto, Yes, No — and they decide whether optional runtime DLLs are copied from beside the export template to beside the exported `.exe`.

The official 4.7.2 template archive is 1.28 GB and holds 35 entries: the platform template executables, the export-template version file, and the other platforms. There is no `libEGL.x86_64.dll`, no `libGLESv2.x86_64.dll`, no `D3D12Core.x86_64.dll`, and no `d3d12SDKLayers.x86_64.dll`. Setting either flag to `1` would copy nothing. The exporter silently skips a missing source file; the export still says success.

That is not an omission. Godot links ANGLE statically when the Windows build is compiled with `angle=yes` — `EGL_STATIC` is defined in `platform/windows/detect.py`, and the template carries the ANGLE code paths (`switching to ANGLE`, the `EGL_PLATFORM_ANGLE_*` attributes, the D3D11 WARP device type). D3D12 is compiled in and loads the system `d3d12.dll`; the template has no `D3D12Core.dll` reference, and the loader falls back to `D3D12CreateDevice` when the Agility SDK factory is not beside it. `0` is not Off. It is "include the optional libraries only when the project asks for that driver, and only the files the template supplies."

The project did not ask for either driver explicitly, and the runtime chain was already enabled by engine defaults. The row's premise was a screenshot of two zeros.

## What Godot actually offers

Godot 4 has three rendering methods, and they are not three settings on one renderer. Each names a different device API and a different feature set:

| Method | Device API | What it is for | The cost |
|---|---|---|---|
| **Forward+** | Vulkan, Direct3D 12, Metal | Desktop; clustered forward rendering, bloom, SSAO, SDFGI, volumetric fog | The heaviest baseline; the 3D vault graph's bloom is built on it |
| **Mobile** | Vulkan, Direct3D 12, Metal | Mobile and lower-power desktop; the Forward+ feature set minus the expensive passes | 592 MB with one pane in the bake-off — 11% below Forward+ — and no bloom |
| **Compatibility** | OpenGL 3.3, OpenGL ES 3.0, ANGLE | The widest reach, including GLES3 devices and ANGLE over D3D11 | 2.2x lighter warm; no bloom; the 2D canvas is unaffected |

On Windows the driver choice is more interesting than the method choice, because a machine can have a Vulkan loader and still fail to create a device, or have no Vulkan at all. Godot's Windows display server tries the requested RenderDevice driver, then the fallbacks:

1. **Vulkan** — the project default for Forward+.
2. **D3D12** — native hardware, or **WARP**, Microsoft's CPU rasterizer, when there is no hardware adapter. This is `Microsoft Basic Render Driver`, the adapter name that appears on a GitHub runner.
3. **Native OpenGL 3** — which on Windows may be the GDI Generic 1.1 implementation, not a usable GLES3 device.
4. **ANGLE** — GLES3 over D3D11, and D3D11 WARP when no hardware adapter exists. The transition is automatic when WGL reports a version below 3.3.
5. **Native OpenGL again** if ANGLE cannot start.

The project now pins that order in `godot/project.godot` — `rendering_device/driver.windows="vulkan"`, `rendering_device/fallback_to_d3d12`, `fallback_to_opengl3`, `gl_compatibility/driver.windows="opengl3"`, `gl_compatibility/fallback_to_angle`, `fallback_to_native` — so the chain is a project decision, not an engine default that a future Godot version can silently change.

The tradeoff is not abstract. The 2026-11-22 bake-off ran the same build through both renderers on the shipped v0.8.5 Linux archive, on an RTX 5070 Ti with Godot 4.7.2 and Vulkan 1.4.363:

| Metric (warm, MiB or ms) | Forward+ | Compatibility |
|---|---:|---:|
| Idle resident, 1 pane | 667 MB | 310 MB |
| Idle resident, 8 panes | 669 MB | 305 MB |
| First launch | 1083 MB | 363 MB |
| Full repaint, 90x30 grid | 1.60 ms | 1.48 ms |
| Full repaint, 200x60 grid | 3.39 ms | 3.72 ms |

Compatibility is 2.2x lighter warm and 3x lighter on a first launch. The repaint costs are within the run-to-run spread. The difference that matters is visual: the orbital vault graph's bloom is the v0.8.6 identity, and Compatibility does not draw it. The decision was Forward+ by default on every platform, with Compatibility as the documented opt-in (`--rendering-driver opengl3`); a per-platform flip is one project-setting override, not an export-preset key. Mobile was rejected because it bought 11% of memory and lost the bloom.

![The orbital vault graph](/images/v0.8.6_3.png)

The other half of the primer is detection. `RendererInfo` reads the live `RenderingServer` driver, method and adapter, matches the adapter against a narrow list of CPU rasterizers (llvmpipe, softpipe, SwiftShader, `Microsoft Basic Render Driver`, Apple's software renderer), and prints one startup line:

```
[renderer] vulkan (forward_plus) on NVIDIA GeForce RTX 5070 Ti | 1920x1080 | scale 1.00 | 164.9 Hz | vsync on | max_fps unlimited | effect crt@0
```

A software adapter earns a warning and a ` · software` marker beside the FPS. That line is what makes an FPS report attributable to the renderer rather than to the terminal, and it is also the seam a test can assert on.

## The chain was already on, but unproven

The runtime chain was enabled by engine defaults. What the project lacked was a job that exercised it. `windows-smoke` runs the Windows GUT suite and the pane-API smoke under `--headless`; under `--headless` Godot selects the dummy renderer, so the `[renderer]` line cannot name Vulkan, D3D12, OpenGL or ANGLE even when one of them would have initialized.

The smoke gained a `--renderer-smoke` mode. It reuses the existing sandbox, `GPTY_TEST_USER_DIR`, `LOCALAPPDATA`/`APPDATA`, the built GDExtension and the `GODOT` path; it launches with `--quit-after 180` and **no** `--headless`; it reads the startup line, requires the named driver, and requires the software-rasterizer warning to name the adapter. `windows-smoke` runs it for `d3d12` and `opengl3_angle` after the GUT import, so a failure is one named step rather than a mystery inside a suite.

The first Windows run found the fallback immediately:

| Launch | Driver (method) | Adapter |
|---|---|---|
| default | `d3d12` (forward_plus) | `Microsoft Basic Render Driver` (WARP) |
| `--rendering-driver d3d12` | `d3d12` (forward_plus) | `Microsoft Basic Render Driver` (WARP) |
| `--rendering-driver opengl3_angle` | `opengl3_angle` (gl_compatibility) | `Google Inc. (Microsoft) ANGLE (Microsoft, Microsoft Basic Render Driver (0x0000008C) Direct3D11 vs_5_0 ps_5_0, D3D11-10.0.26100.33648)` |

The same run also failed the new check, for a reason worth keeping. The check compared the whole adapter string from the `[renderer]` line against one warning line. The startup record runs the adapter through `RendererInfo.device_label`, which prefixes the vendor when the adapter name does not already start with it: `Google Inc. (Microsoft) ANGLE (Microsoft, Microsoft Basic Render Driver ...)`. The warning quotes the raw adapter name, `ANGLE (Microsoft, ...)`, with no vendor prefix. The warning did name the same WARP adapter, but the assertion looked for a spelling the warning never had. The first fix message blamed line wrapping; the parsed prefix was the actual difference. The fix was to match the detector's own software marker — `microsoft basic render` — inside the warning, which is the property the check exists for. The first Windows run therefore proved the renderer and disproved the assertion; the next one recorded all three launches green.

That is the shape of a renderer check that does not overfit: assert the classification, not the full display string. The full string is still printed, so a human can read it.

## The recapture, and the first run's missing focus

The same session ran the v0.8.6 recapture on the 0.8.5 tree (the version bump happens at tag time). The committed harness has 62 states; `scripts/ui-capture` staged each one in a private sandbox and saved the app's own viewport, and `scripts/ui-capture-check` proved the changed states are pixel-identical across two runs.

The 22-surface focus and accessibility audit found no undeclared mouse-only buttons and no unnamed controls: `unaccounted=0` and `unnamed=0` on every surface, every overlay closed on Escape, and every focusable control was reached. The one count that did not line up — the concept editor's `reached=55` against `focusable=54` — is the audit's closed ring counting its first member once more; `unaccounted=0` there too.

The audit did find one real first-run bug. The zero-pane first run reported `focus-owner=<none>`. The empty workspace builds a Getting Started guide whose hero keycap is the surface's one action, and the layout code hands the keyboard to the guide only on a visibility transition (`was_visible` false to true). `EmptyState` started visible, so the first layout never saw a transition. The guide was shown, the keycap was clickable, and a keyboard user had to Tab to reach it. The fix starts `EmptyState` hidden and lets the first layout reveal it; `ShortcutGuide.focus_hero()` focuses the keycap, and `test_an_emptied_workspace_shows_the_guide` asserts the focus owner. A restored workspace with panes does not flash the guide, because the same hidden start covers it.

The release set is five desktop window grabs — first launch/Getting Started, the light chrome over four dark terminals, the orbital graph, Motion and Effects, and a pinned Tint cue — saved as `v0.8.6_1.png` through `v0.8.6_5.png`. The recapture also exercised the real X11 window: resizing it live to 800x500 and 560x340 kept the layout unclipped with no script errors.

Two platform limits stayed limitations and are recorded as such rather than papered over. Window opacity is unavailable on this X11/XWayland session (`settings-opacity-560x340` reads "unavailable on the X11 display server"); the Wayland-driver row owns that. A 2x scale factor could not be exercised: Godot 4.7.2's X11 `screen_get_scale()` reports 1.00 with `Xft.dpi=192` and with an xsettingsd `Gdk/WindowScalingFactor 2` file, and the session has no 2x display. macOS window behaviour has no job that executes the app, and pulse/particles have no still frame in `PaneEffects.pin_cue` — both are linked to their owning rows below.

## What it does now

- The Windows renderer chain is pinned as a project decision and proven by a real-display smoke: Vulkan, then D3D12/WARP, then native OpenGL 3, then static ANGLE over D3D11/WARP.
- `application/export_angle` and `application/export_d3d12` stay 0 (Auto). No runtime DLLs are added, so the Windows archive's file list and size are unchanged.
- Forward+ stays the default on every platform; Compatibility remains the one-flag opt-in.
- The zero-pane first run gives the keyboard to the guide's hero keycap, and the guide starts hidden so a restored workspace never flashes it.

## How it was checked

- `./scripts/ci-check` on the final tree: formatting, clippy, workflow lint, the GUT suite, the live pane-API smoke, the static gates, and the docs and knowledge bundles.
- `scripts/ui-capture-check` on every changed capture state: two runs pixel-identical; the perturbed state the only one that changes.
- The Windows renderer smoke on `windows-smoke`: run 45077452383 green (default and forced `d3d12` on WARP; forced `opengl3_angle` on its D3D11 WARP adapter), and the final PR run 45078402812 green on every job.
- `--audit-focus` and `--audit-accessibility` on 22 surfaces: `unaccounted=0`, `unnamed=0`, `escape overlay ... closed=true`; `first-launch` now names `.../HeroKeycap`.
- Live resize at 800x500 and 560x340 on the real X11 window: geometry confirmed, no clipped controls, no `SCRIPT ERROR`.

## Still missing

The row's Intel-driver-with-no-Vulkan case is unmeasured: the attached machine has an RTX 5070 Ti, and the Windows runner's only adapter is WARP. The forced `opengl3_angle` launch covers the GL path, but a physical Intel machine with no Vulkan remains a named deferral, not a claimed result. The same is true of the X11 opacity and 2x-scale checks and of macOS window behaviour, all recorded in the [v0.9 roadmap](https://github.com/godot-pty/gpty/blob/main/docs/content/docs/roadmap/v0.9.md); the pulse/particles stills are in the [v0.8.7 finish pass](https://github.com/godot-pty/gpty/blob/main/docs/content/docs/roadmap/v0.8.md). The v0.8.6 changelog is release-time work and will carry the renderer decision and the recaptured images.

Source: [github.com/godot-pty/gpty](https://github.com/godot-pty/gpty). The next release's changelog will name the renderer proof, the recapture, and the focus fix.
