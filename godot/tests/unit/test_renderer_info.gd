extends GutTest
# The renderer record: which adapter names mean the engine is rasterizing on
# the CPU, and the one-line startup record that says so. The detector is the
# half a regression would silence - a software launch would then read as a GPU
# launch and its frame rate as the app's cost.

func test_llvmpipe_and_softpipe_are_software():
	assert_true(RendererInfo.is_software("llvmpipe (LLVM 23.1.5, 256 bits)"))
	assert_true(RendererInfo.is_software("Mesa Softpipe"))
	assert_true(RendererInfo.is_software("SOFTWARE RASTERIZER"),
		"the match is case-insensitive")

func test_the_other_cpu_rasterizers_are_software():
	assert_true(RendererInfo.is_software("Google SwiftShader"))
	assert_true(RendererInfo.is_software("Microsoft Basic Render Driver"))
	assert_true(RendererInfo.is_software("Apple Software Renderer"))

func test_a_hardware_adapter_is_not_software():
	for name in [
		"NVIDIA GeForce RTX 5070 Ti",
		"AMD Radeon RX 7900 XTX (RADV NAVI31)",
		"Intel(R) Arc(TM) A770 Graphics",
		"Apple M3 Pro",
		"Mali-G78 MP14",
		"Adreno (TM) 740",
	]:
		assert_false(RendererInfo.is_software(name), "%s is hardware" % name)

func test_the_note_and_the_warning_name_the_state_and_the_fix():
	assert_eq(RendererInfo.NOTE, "software",
		"the status bar marker is the one short word")
	var warning := RendererInfo.warning("Mesa llvmpipe (LLVM 23.1.5, 256 bits)")
	assert_string_contains(warning, "llvmpipe", "the warning names the adapter")
	assert_string_contains(warning, "CPU-bound", "and what the frame rate now measures")
	assert_string_contains(warning, "graphics driver", "and where to look")

func test_a_vendor_is_not_repeated_when_the_adapter_already_names_it():
	assert_eq(RendererInfo.device_label("NVIDIA GeForce RTX 5070 Ti",
		"NVIDIA Corporation", "forward_plus", "vulkan"),
		"vulkan (forward_plus) on NVIDIA GeForce RTX 5070 Ti")
	assert_eq(RendererInfo.device_label("llvmpipe (LLVM 23.1.5, 256 bits)",
		"Mesa", "gl_compatibility", "opengl3_es"),
		"opengl3_es (gl_compatibility) on Mesa llvmpipe (LLVM 23.1.5, 256 bits)")

func test_the_startup_record_carries_every_fact_a_frame_report_needs():
	var line := RendererInfo.describe("llvmpipe (LLVM 23.1.5, 256 bits)", "Mesa",
		"gl_compatibility", "opengl3_es", Vector2i(1720, 1382), 164.87, "on",
		165, "crt", 2)
	for part in ["opengl3_es", "gl_compatibility", "Mesa llvmpipe",
			"1720x1382", "164.9 Hz", "vsync on", "max_fps 165", "effect crt@2"]:
		assert_string_contains(line, part)

func test_an_unknown_refresh_and_an_unlimited_cap_read_as_words():
	var line := RendererInfo.describe("Adapter", "", "gl_compatibility", "opengl3_es",
		Vector2i(800, 500), 0.0, "off", 0, "", 0)
	assert_string_contains(line, "refresh unknown")
	assert_string_contains(line, "max_fps unlimited")
	assert_string_contains(line, "effect none@0")

func test_the_vsync_modes_are_named_by_their_labels():
	assert_eq(RendererInfo.vsync_label(DisplayServer.VSYNC_DISABLED), "off")
	assert_eq(RendererInfo.vsync_label(DisplayServer.VSYNC_ENABLED), "on")
	assert_eq(RendererInfo.vsync_label(DisplayServer.VSYNC_ADAPTIVE), "adaptive")
	assert_eq(RendererInfo.vsync_label(DisplayServer.VSYNC_MAILBOX), "mailbox")
	assert_eq(RendererInfo.vsync_label(99), "mode 99",
		"an unknown mode is still reported, not blank")
