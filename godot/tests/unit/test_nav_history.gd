extends GutTest
# NavHistory — the About tab's bounded back/forward trail. Pure: no scene tree,
# no documents. The rules under test are the ones the viewer promises: the root
# is always the oldest entry, a new page truncates the forward tail, and the
# cap bounds both lists.

func test_a_fresh_history_with_a_root_has_nowhere_to_go():
	var history := NavHistory.new("README.md")
	assert_eq(history.current(), "README.md")
	assert_eq(history.size(), 1)
	assert_false(history.can_back())
	assert_false(history.can_forward())
	assert_eq(history.back(), "", "back at the root answers no page")
	assert_eq(history.current(), "README.md", "and the cursor did not move")

func test_push_back_and_forward_walk_the_trail():
	var history := NavHistory.new("README.md")
	history.push("SECURITY.md")
	history.push("ROADMAP.md")
	assert_eq(history.current(), "ROADMAP.md")
	assert_true(history.can_back())
	assert_false(history.can_forward())
	assert_eq(history.back(), "SECURITY.md")
	assert_eq(history.back(), "README.md")
	assert_false(history.can_back(), "the root is the last back link")
	assert_eq(history.forward(), "SECURITY.md")
	assert_eq(history.forward(), "ROADMAP.md")
	assert_false(history.can_forward())

func test_pushing_the_current_page_is_a_no_op():
	var history := NavHistory.new("README.md")
	history.push("SECURITY.md")
	history.push("SECURITY.md")
	assert_eq(history.size(), 2, "clicking the open page must not add a step")
	history.push("")
	assert_eq(history.size(), 2, "an empty entry names no page")

func test_a_new_page_replaces_the_forward_tail():
	var history := NavHistory.new("README.md")
	history.push("A.md")
	history.push("B.md")
	history.back()
	history.push("C.md")
	assert_eq(history.current(), "C.md")
	assert_false(history.can_forward(), "B was replaced by the new page")
	assert_eq(history.back(), "A.md")

func test_the_cap_drops_the_second_entry_and_keeps_the_root():
	var history := NavHistory.new("README.md", 4)
	for page in ["a.md", "b.md", "c.md", "d.md"]:
		history.push(page)
	assert_eq(history.size(), 4, "the cap bounds the trail")
	var trail: Array[String] = []
	while history.can_back():
		trail.append(history.back())
	assert_eq(trail, ["c.md", "b.md", "README.md"],
		"the oldest kept page is the second entry, and the root survives every drop")
	assert_eq(history.current(), "README.md")

func test_a_cap_of_one_still_answers_the_root():
	var history := NavHistory.new("README.md", 1)
	history.push("A.md")
	assert_eq(history.size(), 1)
	assert_eq(history.current(), "README.md")
	assert_false(history.can_back())

func test_an_unpinned_history_drops_its_oldest_entry():
	var history := NavHistory.new("", 2)
	history.push("a.md")
	history.push("b.md")
	history.push("c.md")
	assert_eq(history.size(), 2)
	assert_eq(history.current(), "c.md")
	assert_eq(history.back(), "b.md")
	assert_false(history.can_back())
