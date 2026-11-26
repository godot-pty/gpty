class_name RendererInfo
extends RefCounted
## What the window is drawing through, named once at startup.
##
## Godot falls back by itself when a GPU context cannot be created (Vulkan ->
## OpenGL 3 -> OpenGL ES), and on a machine whose drivers are unusable the last
## step is a CPU rasterizer such as Mesa's llvmpipe. The app still draws a
## full-resolution window, so every frame is CPU-bound: the status bar's FPS is
## then a measurement of the rasterizer, not of gPTY's paint. This class puts
## that state in the log and gives the bar a marker, so an FPS report cannot be
## read as a GPU frame time by mistake.

## Adapter-name fragments that mean the driver rasterizes on the CPU. Matched
## case-insensitively; the list stays narrow so a hardware adapter cannot carry
## one of these words by accident.
const SOFTWARE_MARKERS := [
	"llvmpipe",              # Mesa's LLVM rasterizer (Linux)
	"softpipe",              # Mesa's reference rasterizer
	"swiftshader",           # Google's CPU rasterizer (Chrome/ANGLE)
	"software rasterizer",
	"microsoft basic render",  # WARP (Windows)
	"apple software renderer",
]
## The status-bar marker beside the FPS. Short because it shares one label with
## the clock and the version.
const NOTE := "software"
## What to do about it. Kept beside the detector so the warning, and any later
## surface that shows the same state, cannot drift apart. The kernel-module
## sentence is Linux-only: Windows and macOS have no loaded module to mismatch.
const HINT := "Check the graphics driver before treating the frame rate as a gPTY cost."
const LINUX_HINT := " After a Linux driver upgrade, the loaded kernel module only matches the userspace driver after a restart."

static func is_software(adapter_name: String) -> bool:
	var name := adapter_name.to_lower()
	for marker in SOFTWARE_MARKERS:
		if name.contains(marker):
			return true
	return false

## "opengl3_es (gl_compatibility) on Mesa llvmpipe (LLVM 23.1.5, 256 bits)".
## The vendor is prefixed unless the adapter name already starts with its first
## word (NVIDIA's names carry "NVIDIA", AMD's "AMD"; Mesa's "llvmpipe" does not
## carry "Mesa").
static func device_label(adapter_name: String, adapter_vendor: String,
		rendering_method: String, driver: String) -> String:
	var device := adapter_name
	var vendor_key := adapter_vendor.to_lower().get_slice(" ", 0)
	if adapter_vendor != "" and not adapter_name.to_lower().begins_with(vendor_key):
		device = "%s %s" % [adapter_vendor, adapter_name]
	return "%s (%s) on %s" % [driver, rendering_method, device]

## The startup record: renderer and device, viewport, device scale, refresh,
## vsync, frame cap and the ambient effect. The scale matters on macOS Retina
## and Windows HiDPI, where the viewport is logical and the framebuffer is
## `scale` times larger. This is ids and modes only, never program content.
static func describe(adapter_name: String, adapter_vendor: String,
		rendering_method: String, driver: String, viewport: Vector2i,
		refresh_hz: float, scale: float, vsync: String, max_fps: int,
		effect: String, intensity: int) -> String:
	var parts := PackedStringArray()
	parts.append(device_label(adapter_name, adapter_vendor, rendering_method, driver))
	parts.append("%dx%d" % [viewport.x, viewport.y])
	parts.append("scale %.2f" % scale)
	if refresh_hz > 0.0:
		parts.append("%.1f Hz" % refresh_hz)
	else:
		parts.append("refresh unknown")
	if vsync != "":
		parts.append("vsync " + vsync)
	parts.append("max_fps %s" % ("unlimited" if max_fps == 0 else str(max_fps)))
	var effect_name := effect if effect != "" else "none"
	parts.append("effect %s@%d" % [effect_name, intensity])
	return " | ".join(parts)

static func vsync_label(mode: int) -> String:
	match mode:
		DisplayServer.VSYNC_DISABLED:
			return "off"
		DisplayServer.VSYNC_ENABLED:
			return "on"
		DisplayServer.VSYNC_ADAPTIVE:
			return "adaptive"
		DisplayServer.VSYNC_MAILBOX:
			return "mailbox"
	return "mode %d" % mode

## The warning a software rasterizer earns: what happened and what it costs.
static func hint() -> String:
	if OS.get_name() == "Linux":
		return HINT + LINUX_HINT
	return HINT

static func warning(adapter_name: String) -> String:
	return "software rasterizer \"%s\": no GPU context was created, so every frame and every effect is CPU-bound. %s" % [
		adapter_name, hint()]

## Glow is a Forward+ feature; Mobile and Compatibility ignore the setting.
static func supports_glow(rendering_method: String) -> bool:
	return rendering_method == "forward_plus"

## The About tab's line: the renderer the engine actually runs, with the
## software state called out because it changes what the frame rate means.
static func about_text() -> String:
	var adapter := RenderingServer.get_video_adapter_name()
	var line := device_label(adapter, RenderingServer.get_video_adapter_vendor(),
		RenderingServer.get_current_rendering_method(),
		RenderingServer.get_current_rendering_driver_name())
	if is_software(adapter):
		line += " - software rasterizer, CPU-bound"
	return line

## Read the live engine and write the startup record. The workspace calls this
## once at startup; returns whether the adapter is a software rasterizer, which
## is what the caller puts in the status bar.
static func report(effect: String, intensity: int) -> bool:
	var adapter := RenderingServer.get_video_adapter_name()
	# The window can be on a display other than the primary one; its refresh and
	# scale are the ones the frame rate and the framebuffer actually use.
	var screen := DisplayRate.current_screen()
	print("[renderer] %s" % describe(adapter,
		RenderingServer.get_video_adapter_vendor(),
		RenderingServer.get_current_rendering_method(),
		RenderingServer.get_current_rendering_driver_name(),
		DisplayServer.window_get_size(), DisplayRate.rate_for(screen),
		DisplayServer.screen_get_scale(screen),
		vsync_label(DisplayServer.window_get_vsync_mode()), Engine.max_fps,
		effect, intensity))
	var software := is_software(adapter)
	if software:
		push_warning("[renderer] %s" % warning(adapter))
	return software
