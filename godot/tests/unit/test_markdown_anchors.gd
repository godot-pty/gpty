extends GutTest
# MarkdownAnchors — the source-side half of wikilink navigation. A fragment
# (`[[note#heading]]`) and a link-panel row (a 1-based source line) both name a
# place in a note the preview does not number the same way, so this scanner
# answers "which heading" and MarkdownView finds that heading in the rendered
# text. The rules that matter: ATX only, code fences are literal, a leading
# properties block is not content, and matching is exact then case-insensitive.


func test_atx_headings_carry_their_line_and_text():
	var headings := MarkdownAnchors.headings("# Title\n\ntext\n\n## Part Two\n")
	assert_eq(headings.size(), 2)
	assert_eq(int(headings[0]["line"]), 1)
	assert_eq(str(headings[0]["text"]), "Title")
	assert_eq(int(headings[1]["line"]), 5)
	assert_eq(str(headings[1]["text"]), "Part Two")


func test_a_closing_hash_run_is_syntax_only_after_whitespace():
	var headings := MarkdownAnchors.headings("## Part ##\n# C#\n### trailing ###\n")
	assert_eq(headings.size(), 3)
	assert_eq(str(headings[0]["text"]), "Part")
	assert_eq(str(headings[1]["text"]), "C#", "a sharp inside a word is text")
	assert_eq(str(headings[2]["text"]), "trailing")


func test_a_heading_needs_one_to_six_hashes_and_a_separator():
	assert_eq(MarkdownAnchors.headings("####### seven\n").size(), 0)
	assert_eq(MarkdownAnchors.headings("#NoSpace\n").size(), 0)
	assert_eq(MarkdownAnchors.headings("    # four spaces is code\n").size(), 0,
		"an indented line is a code block, not a heading")
	assert_eq(MarkdownAnchors.headings("   # three spaces is a heading\n").size(), 1)


func test_a_fenced_hash_is_literal_text():
	var source := "# Real\n\n```md\n# Not a heading\n```\n\n~~~\n## Also not\n~~~\n\n## After\n"
	var headings := MarkdownAnchors.headings(source)
	var texts := headings.map(func(h): return str(h["text"]))
	assert_eq(texts, ["Real", "After"])


func test_a_leading_properties_block_is_skipped():
	var source := "---\ntitle: Note\n# not the title\n---\n# Real Title\n"
	var headings := MarkdownAnchors.headings(source)
	assert_eq(headings.size(), 1, "frontmatter is data, not content")
	assert_eq(str(headings[0]["text"]), "Real Title")
	assert_eq(int(headings[0]["line"]), 5)


func test_an_unterminated_properties_marker_is_not_frontmatter():
	# A leading `---` with no closer may be a horizontal rule; the rule that
	# treats it as data needs a closing marker, exactly like note_title.
	var headings := MarkdownAnchors.headings("---\n# Still a heading\n")
	assert_eq(headings.size(), 1)
	assert_eq(str(headings[0]["text"]), "Still a heading")


func test_crlf_lines_are_the_same_lines():
	var headings := MarkdownAnchors.headings("# One\r\n\r\ntext\r\n## Two\r\n")
	assert_eq(headings.size(), 2)
	assert_eq(str(headings[0]["text"]), "One")
	assert_eq(int(headings[1]["line"]), 4)


func test_nearest_is_the_last_heading_at_or_before_a_line():
	var source := "# Top\n\nbody\n\n## Middle\n\nbody\n\n### Deep\n\nbody\n"
	assert_eq(MarkdownAnchors.nearest(source, 1), "Top")
	assert_eq(MarkdownAnchors.nearest(source, 5), "Middle")
	assert_eq(MarkdownAnchors.nearest(source, 8), "Middle")
	assert_eq(MarkdownAnchors.nearest(source, 9), "Deep")
	assert_eq(MarkdownAnchors.nearest(source, 0), "", "no line has no anchor")


func test_a_line_before_the_first_heading_has_no_anchor():
	assert_eq(MarkdownAnchors.nearest("intro text\n\n# Later\n", 1), "")


func test_find_prefers_an_exact_match_then_case():
	var source := "# part\n\n## Part\n\n### PART\n"
	assert_eq(MarkdownAnchors.find(source, "Part"), 3, "exact text wins")
	assert_eq(MarkdownAnchors.find(source, "pArT"), 1, "then the first case-insensitive")
	assert_eq(MarkdownAnchors.find(source, " part "), 1, "the fragment is trimmed")
	assert_eq(MarkdownAnchors.find(source, "missing"), 0)
	assert_eq(MarkdownAnchors.find(source, ""), 0)
