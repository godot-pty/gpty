class_name ViewableFiles
extends RefCounted
# One closed table: which paths the in-app code viewer can show.
#
# This exists because the file tree's fallback is the system's default
# handler, which both leaves gPTY and is the sharper sink (a downloaded
# `.desktop` file is *run* by the handler, not displayed). The table is
# deliberately an allowlist of text formats the viewer renders read-only — no
# content sniffing: a path's extension (lowercased) or one of a few
# extensionless names decides, so the answer is predictable, testable, and
# everything else keeps the existing confirmation path unchanged.
#
# Adding a type is one entry here plus a test in `test_viewable_files.gd`;
# without an entry a file is never opened in a pane.

const VIEWER := "code_viewer"

## Text extensions the viewer renders: source, config/data, and docs/prose.
const EXTENSIONS: Array[String] = [
	# Source
	"rs", "gd", "py", "pyi", "js", "mjs", "cjs", "jsx", "ts", "tsx",
	"c", "h", "cc", "cpp", "cxx", "hpp", "hxx", "hh",
	"go", "java", "kt", "kts", "rb", "php", "cs", "swift", "lua", "pl", "pm",
	"sh", "bash", "zsh", "fish", "ps1", "bat", "cmd", "sql",
	"ex", "exs", "erl", "hrl", "hs", "clj", "cljs", "cljc", "edn",
	"scala", "dart", "zig", "nim", "v", "asm", "s", "m", "mm", "sol",
	"vue", "svelte", "html", "htm", "css", "scss", "sass", "less",
	"glsl", "vert", "frag", "comp", "gdshader", "hlsl", "metal",
	"proto", "graphql", "gql",
	# Config and data
	"toml", "yaml", "yml", "json", "jsonc", "json5", "xml", "xsd",
	"ini", "cfg", "conf", "properties", "env", "lock", "csv", "tsv",
	# Docs and prose
	"md", "markdown", "rst", "adoc", "asciidoc", "org", "txt", "text",
	"log", "diff", "patch", "tex",
]

## Extensionless files that are text by convention. Exact names — a suffix
## (`Dockerfile.dev`) makes it a different file, and the list stays small
## enough to read. `makefile`/`justfile` lowercase variants are common too.
const NAMES: Array[String] = [
	"Makefile", "makefile", "GNUmakefile", "Dockerfile", "Containerfile",
	"LICENSE", "Justfile", "justfile",
]

## The viewer for `path`, or "" when the file tree must keep the
## confirm-then-system path.
static func viewer_for(path: String) -> String:
	var name := path.get_file()
	if name in NAMES:
		return VIEWER
	var ext := name.get_extension().to_lower()
	if ext != "" and ext in EXTENSIONS:
		return VIEWER
	return ""
