extends Node
# Autoload: polls GitHub Releases on startup, notifies if update available.
# Non-blocking — runs in background, degrades silently on network errors.

const REPO_OWNER := "you"
const REPO_NAME := "gpty"
const RELEASES_URL := "https://api.github.com/repos/%s/%s/releases/latest"

const REQUEST_TIMEOUT := 5.0

var _http: HTTPRequest

func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS
	_check()

func _check():
	var current = ProjectSettings.get_setting("application/config/version", "0.0.0")
	if current == "0.0.0":
		return  # dev build, skip

	# Skip update check when installed via system package manager
	# (AUR, apt, dnf, etc.) — updates come through the package manager.
	if OS.get_executable_path().begins_with("/usr/"):
		return
	_http = HTTPRequest.new()
	_http.timeout = REQUEST_TIMEOUT
	add_child(_http)
	_http.request_completed.connect(_on_response.bind(current))
	var url = RELEASES_URL % [REPO_OWNER, REPO_NAME]
	var err = _http.request(url, ["Accept: application/vnd.github+json"])
	if err != OK:
		_http.queue_free()

func _on_response(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, current: String):
	# Always clean up the HTTPRequest node — success or failure.
	_http.queue_free()

	# result != 0 means network-level failure: offline, DNS error, timeout, etc.
	# Degrade silently — the user is offline, nothing we can do.
	if result != HTTPRequest.RESULT_SUCCESS:
		return

	# GitHub may rate-limit or return non-200. Degrade silently.
	if code != 200:
		return

	var json = JSON.parse_string(body.get_string_from_utf8())
	if json == null:
		return
	var latest = json.get("tag_name", "").lstrip("v")
	if latest == "" or latest == current:
		return

	if not _is_newer(latest, current):
		return

	ToastManager.info("Update available: v%s → v%s" % [current, latest])

func _is_newer(latest: String, current: String) -> bool:
	var la = latest.split(".")
	var ca = current.split(".")
	var n = mini(la.size(), ca.size())
	for i in n:
		var lv = la[i].to_int()
		var cv = ca[i].to_int()
		if lv > cv: return true
		if lv < cv: return false
	return la.size() > ca.size()
