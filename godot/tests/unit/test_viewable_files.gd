extends GutTest
# ViewableFiles is the one closed table behind "open this file in a pane":
# a path's extension (lowercased) or one of a few exact names decides, and
# everything else stays on the confirmation-then-system path.

func test_source_config_and_docs_extensions_open_in_the_viewer():
	for path in [
		"/p/main.rs", "/p/worker.gd", "/p/tool.py", "/p/app.ts",
		"/p/config.toml", "/p/Config.yaml", "/p/data.json", "/p/build.xml",
		"/p/README.md", "/p/notes.markdown", "/p/run.log", "/p/fix.diff",
	]:
		assert_eq(ViewableFiles.viewer_for(path), ViewableFiles.VIEWER, path)

func test_extensions_are_case_insensitive():
	for path in ["/p/MAIN.RS", "/p/Notes.Markdown", "/p/Config.YML", "/p/old.PATCH"]:
		assert_eq(ViewableFiles.viewer_for(path), ViewableFiles.VIEWER, path)

func test_extensionless_names_are_exact():
	for name in ["Makefile", "Dockerfile", "LICENSE", "Justfile"]:
		assert_eq(ViewableFiles.viewer_for("/p/" + name), ViewableFiles.VIEWER, name)
	assert_eq(ViewableFiles.viewer_for("/p/Dockerfile.dev"), "",
		"a suffix makes it a different file, not the listed name")

func test_unsupported_paths_stay_on_the_system_path():
	for path in [
		"/p/photo.png", "/p/archive.zip", "/p/setup.desktop",
		"/p/program.exe", "/p/video.mp4", "/p/binary",
	]:
		assert_eq(ViewableFiles.viewer_for(path), "", path)

func test_a_path_without_a_name_is_not_viewable():
	assert_eq(ViewableFiles.viewer_for(""), "")
	assert_eq(ViewableFiles.viewer_for("/"), "")
