extends GutTest
# FeedbackText — the sidebar Feedback row's issue title, body and URL.
# Defends: the body carries the four allowed build facts and nothing else, a
# hostile field cannot forge a block line, and the URL stays under GitHub's
# limit with the build block intact.

const ABOUT := {
	"version": "0.8.0",
	"os": "Linux",
	"os_version": "6.10.2",
	"window_mode": "System Frame",
}

const EXPECTED_BODY := """What happened:

What I expected:

Steps to reproduce:
1.
2.
3.

---
About this build
- gPTY 0.8.0
- Linux 6.10.2
- Window: System Frame"""

func test_the_body_names_the_three_prompts_and_the_build_block():
	assert_eq(FeedbackText.body(ABOUT), EXPECTED_BODY)

func test_a_missing_field_degrades_to_a_placeholder_line():
	var body := FeedbackText.body({})
	var lines := body.split("\n")
	assert_eq(lines.size(), 14, "the block still names three lines")
	assert_eq(lines[11], "- gPTY unknown")
	assert_eq(lines[12], "- unknown OS")
	assert_eq(lines[13], "- Window: unknown")

func test_a_field_with_newlines_cannot_break_the_block():
	var about := ABOUT.duplicate()
	about["os_version"] = "6.10.2\n## Injected heading"
	var body := FeedbackText.body(about)
	assert_eq(body.split("\n").size(), EXPECTED_BODY.split("\n").size(),
		"a newline inside a value is folded, not honoured")
	assert_eq(body, EXPECTED_BODY.replace("6.10.2", "6.10.2 ## Injected heading"),
		"the value stays on its own line")
	assert_false(FeedbackText.body({}).contains("##"), "no user field can open a heading")

func test_the_url_carries_only_title_and_body():
	var url := FeedbackText.url(ABOUT)
	assert_true(url.begins_with(FeedbackText.ISSUE_URL + "?title="))
	assert_string_contains(url, "&body=")
	for forbidden in ["labels=", "assignees=", "template=", "projects="]:
		assert_false(url.contains(forbidden), "the URL must not carry " + forbidden)
	var decoded := url.uri_decode()
	assert_string_contains(decoded, "0.8.0")
	assert_string_contains(decoded, "About this build")
	assert_string_contains(decoded, "Window: System Frame")

func test_an_overlong_field_is_capped_and_the_block_survives():
	var about := ABOUT.duplicate()
	about["os_version"] = "a".repeat(20000)
	var url := FeedbackText.url(about)
	assert_lte(url.length(), FeedbackText.MAX_URL, "the URL stays under the cap")
	var decoded := url.uri_decode()
	assert_string_contains(decoded, "\u2026", "the field is cut with an ellipsis")
	assert_true(decoded.ends_with("- Window: System Frame"),
		"the build block's last line survives")

func test_a_body_over_the_cap_is_trimmed_with_a_marker():
	var raw := "prompt\n".repeat(4000) + FeedbackText.BLOCK_MARKER \
		+ "- gPTY 0.8.0\n- Linux 6.10.2\n- Window: System Frame"
	var out := FeedbackText.trimmed(raw)
	assert_ne(out, raw, "an over-cap body is cut")
	var head := FeedbackText.ISSUE_URL + "?title=" \
		+ FeedbackText.TITLE_PREFIX.uri_encode() + "&body="
	assert_lte((head + out.uri_encode()).length(), FeedbackText.MAX_URL,
		"the trimmed body produces a URL under the cap")
	assert_true(out.ends_with(FeedbackText.TRUNCATED), "the cut is marked")
	assert_string_contains(out, "- Window: System Frame",
		"the build block is kept whole")

func test_a_body_under_the_cap_is_untouched():
	assert_eq(FeedbackText.trimmed(EXPECTED_BODY), EXPECTED_BODY)
