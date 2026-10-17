//! Safe CommonMark/GFM subset rendered as Godot `RichTextLabel` BBCode.
//!
//! Markdown is untrusted model/file content. Raw HTML and BBCode are escaped,
//! images are reduced to alt text, and only conservative URL metadata is
//! emitted. `RichTextLabel` never receives source-controlled BBCode tags.
//!
//! The GUI thread runs the render, so the source is capped — but a cap a
//! reader is never told about turns "the pane shows a 900 KiB note" into "the
//! pane shows half of it, silently". [`render`] therefore answers the rendered
//! BBCode *and* what it took ([`Rendered`]), and [`MAX_MARKDOWN_BYTES`] is the
//! same number the panes read under, so a document at a pane's read cap
//! renders whole and only genuinely larger sources (a pasted buffer, a
//! captured command's output, a long model turn) hit the cap at all.

use godot::prelude::*;
use pulldown_cmark::{CodeBlockKind, Event, HeadingLevel, Options, Parser, Tag, TagEnd};

/// Longest Markdown source rendered in one call.
///
/// A cap is needed because the render runs on the GUI thread and its input is
/// untrusted (a paste, a model stream, a captured command). It is deliberately
/// **the** read cap rather than a smaller number of its own — the panes read
/// at most `TextRead.DEFAULT_MAX_BYTES` (`godot/scenes/panes/text_read.gd`) and
/// the vault reads at most `gpty_core::vault::MAX_NOTE_BYTES`, both 1 MiB — so
/// a pane that shows a document at its read cap renders all of it, and one cut
/// (not two) is what a reader has to be told about.
///
/// Measured, per size, with the `probe_render_cost` probe over a repeated
/// Markdown block — this render alone, debug / release: 256 KiB ≈ 30 / 5 ms,
/// 512 KiB ≈ 55 / 9 ms, 1 MiB ≈ 107 / 14 ms, 2 MiB ≈ 214 / 27 ms. Linear, so
/// the cap bounds one GUI-thread call rather than marking a cliff; it is not
/// lowered for speed, because a note at the cap must render whole.
///
/// The render is not the whole cost of showing one: a `RichTextLabel` then
/// parses and shapes the BBCode it is handed (about 1.7× the source). Measured
/// on the GUI thread through `MarkdownView.render_now` + `get_parsed_text` in
/// the debug build the test harness runs: 256 KiB ≈ 74 ms, 512 KiB ≈ 157 ms,
/// 1 MiB ≈ 336 ms. That is a live preview's cost while the preview is on
/// screen — `edit` mode renders nothing, and a document is only re-rendered
/// when the buffer changes — which is why the panes keep the preview
/// optional rather than making it the editor.
///
/// The *shape* pass that follows a render (in the frame after the text lands)
/// is the third cost, and it is the one that can stop being linear: Godot lays
/// a `[ul]`/`[ol]` list out superlinearly in the number of items, so a
/// list-dense document is the worst case. Measured (headless, the Godot 4.7.2
/// binary the app ships against, ~1.7 MiB of rendered BBCode, one tag form per
/// document): two-item lists 38915 ms — and a real 1 MiB note 146705 ms —
/// against 819 ms for that same rendered text with the list tags stripped and
/// 0.5–1.3 s for every other construct (headings, quotes, inline code, links,
/// tables). So this renderer emits **no list tags at all**: each item is a
/// `• `/`N. ` line inside one `[indent]` per list, which renders identically
/// (checked against the tag form side by side) and keeps the layout linear —
/// a `[ul]` in this output is a freeze measured in minutes, not a style
/// preference.
const MAX_MARKDOWN_BYTES: usize = 1 << 20;

/// One render's result: the BBCode, and the source it came from.
///
/// `truncated` and the byte counts travel with the text so a caller can say
/// what is not on screen (the same shape a pane's read answers —
/// `TextRead.read_prefix` — and for the same reason).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rendered {
    /// The BBCode, rendered from `shown` bytes of the source.
    pub text: String,
    /// The source was cut: it is longer than [`MAX_MARKDOWN_BYTES`].
    pub truncated: bool,
    /// Bytes of source actually rendered.
    pub shown: usize,
    /// Bytes of source the caller passed.
    pub size: usize,
}

#[derive(GodotClass)]
#[class(base = RefCounted)]
struct GptyMarkdown;

#[godot_api]
impl IRefCounted for GptyMarkdown {
    fn init(_base: Base<RefCounted>) -> Self {
        Self
    }
}

#[godot_api]
impl GptyMarkdown {
    /// Convert untrusted Markdown to sanitized `RichTextLabel` BBCode (JSON).
    ///
    /// Markdown is model/file content: raw HTML and BBCode are escaped, images
    /// are reduced to alt text, and only conservative `http`/`https`/`mailto`
    /// links become metadata, so `RichTextLabel` never receives
    /// source-controlled tags.
    ///
    /// Answers `{"text", "truncated", "shown", "size"}`: the BBCode, whether
    /// the source was cut at [`MAX_MARKDOWN_BYTES`], and how many bytes were
    /// rendered of how many were given. `truncated` is what lets a view say
    /// what it did not render instead of showing a prefix in silence.
    #[func]
    fn render(&self, markdown: GString) -> GString {
        let rendered = render_markdown(&markdown.to_string());
        let document = serde_json::json!({
            "text": rendered.text,
            "truncated": rendered.truncated,
            "shown": rendered.shown,
            "size": rendered.size,
        })
        .to_string();
        GString::from(document.as_str())
    }
}

fn render_markdown(markdown: &str) -> Rendered {
    let source = truncate_utf8(markdown, MAX_MARKDOWN_BYTES);
    let mut options = Options::empty();
    options.insert(Options::ENABLE_STRIKETHROUGH);
    options.insert(Options::ENABLE_TABLES);
    options.insert(Options::ENABLE_TASKLISTS);
    options.insert(Options::ENABLE_GFM);

    let mut out = String::with_capacity(source.len() + source.len() / 4);
    let mut safe_links = Vec::new();
    let mut lists: Vec<OpenList> = Vec::new();
    for event in Parser::new_ext(source, options) {
        match event {
            Event::Start(Tag::Link { dest_url, .. }) => {
                let safe = safe_url(&dest_url);
                safe_links.push(safe);
                if safe {
                    out.push_str("[url=");
                    out.push_str(&dest_url);
                    out.push(']');
                } else {
                    out.push_str("[u]");
                }
            }
            Event::End(TagEnd::Link) => {
                out.push_str(if safe_links.pop().unwrap_or(false) {
                    "[/url]"
                } else {
                    "[/u]"
                });
            }
            Event::Start(tag) => start_tag(&mut out, tag, &mut lists),
            Event::End(tag) => end_tag(&mut out, tag, &mut lists),
            Event::Text(text) => escape_bbcode_into(&mut out, &text),
            Event::Code(text) => {
                out.push_str("[code]");
                escape_bbcode_into(&mut out, &text);
                out.push_str("[/code]");
            }
            Event::Html(text) | Event::InlineHtml(text) => escape_bbcode_into(&mut out, &text),
            Event::SoftBreak | Event::HardBreak => out.push('\n'),
            Event::Rule => out.push_str("[hr]\n"),
            Event::TaskListMarker(checked) => {
                out.push_str(if checked { "☑ " } else { "☐ " });
            }
            Event::FootnoteReference(name) => {
                out.push('[');
                escape_bbcode_into(&mut out, &name);
                out.push(']');
            }
            Event::InlineMath(text) | Event::DisplayMath(text) => {
                out.push_str("[code]");
                escape_bbcode_into(&mut out, &text);
                out.push_str("[/code]");
            }
        }
    }
    Rendered {
        text: out,
        truncated: source.len() < markdown.len(),
        shown: source.len(),
        size: markdown.len(),
    }
}

/// One open list, so an item can carry its own bullet or number.
///
/// This state exists because the list *tags* are not used (see the module
/// docs): with `[indent]` + a literal prefix the numbering is ours, which also
/// means a list starting at 3 renders as `3.` rather than as `[ol]`'s 1.
struct OpenList {
    ordered: bool,
    next: u64,
}

fn start_tag(out: &mut String, tag: Tag<'_>, lists: &mut Vec<OpenList>) {
    match tag {
        Tag::Paragraph => {}
        Tag::Heading { level, .. } => {
            out.push_str("[font_size=");
            out.push_str(heading_size(level));
            out.push_str("][b]");
        }
        Tag::BlockQuote(_) => out.push_str("[indent]> "),
        Tag::CodeBlock(kind) => {
            out.push_str("[code]");
            if let CodeBlockKind::Fenced(language) = kind
                && !language.is_empty()
            {
                escape_bbcode_into(out, &language);
                out.push('\n');
            }
        }
        Tag::HtmlBlock => {}
        Tag::List(start) => {
            // No `[ul]`/`[ol]`: Godot's list layout is superlinear in the
            // item count and this output feeds a live preview (the module
            // docs carry the measured 38915 ms → 819 ms difference), so a
            // list is one `[indent]` plus a literal prefix per item. A nested
            // list opens its own indent, which is what the nested tag did.
            if !lists.is_empty() && !out.ends_with('\n') {
                // A nested list is a block of its own; the outer item's text
                // does not run into it. A loose item's paragraph already
                // ended a line, so this only fills the gap a tight item
                // leaves (and never doubles a blank line).
                out.push('\n');
            }
            lists.push(OpenList {
                ordered: start.is_some(),
                next: start.unwrap_or(1),
            });
            out.push_str("[indent]");
        }
        Tag::Item => {
            if let Some(list) = lists.last_mut() {
                if list.ordered {
                    out.push_str(&list.next.to_string());
                    out.push_str(". ");
                    list.next += 1;
                } else {
                    out.push_str("• ");
                }
            }
        }
        Tag::FootnoteDefinition(name) => {
            out.push_str("[b]");
            escape_bbcode_into(out, &name);
            out.push_str("[/b] ");
        }
        Tag::DefinitionList => out.push_str("[indent]"),
        Tag::DefinitionListTitle => out.push_str("[b]"),
        Tag::DefinitionListDefinition => out.push_str("[indent]"),
        Tag::Table(alignments) => {
            out.push_str("[table=");
            out.push_str(&alignments.len().max(1).to_string());
            out.push(']');
        }
        Tag::TableHead | Tag::TableRow => {}
        Tag::TableCell => out.push_str("[cell]"),
        Tag::Emphasis => out.push_str("[i]"),
        Tag::Strong => out.push_str("[b]"),
        Tag::Strikethrough => out.push_str("[s]"),
        Tag::Link { .. } => unreachable!("links are handled with state in render_markdown"),
        Tag::Image { .. } => out.push_str("[i]Image: "),
        Tag::MetadataBlock(_) => {}
        Tag::Superscript => out.push_str("[sup]"),
        Tag::Subscript => out.push_str("[sub]"),
    }
}

fn end_tag(out: &mut String, tag: TagEnd, lists: &mut Vec<OpenList>) {
    match tag {
        TagEnd::Paragraph => out.push_str("\n\n"),
        TagEnd::Heading(_) => out.push_str("[/b][/font_size]\n"),
        TagEnd::BlockQuote(_) => out.push_str("[/indent]\n"),
        TagEnd::CodeBlock => out.push_str("[/code]\n\n"),
        TagEnd::HtmlBlock => {}
        TagEnd::List(_) => {
            lists.pop();
            out.push_str("[/indent]\n");
        }
        TagEnd::Item => out.push('\n'),
        TagEnd::FootnoteDefinition => out.push('\n'),
        TagEnd::DefinitionList => out.push_str("[/indent]\n"),
        TagEnd::DefinitionListTitle => out.push_str("[/b]\n"),
        TagEnd::DefinitionListDefinition => out.push_str("[/indent]\n"),
        TagEnd::Table => out.push_str("[/table]\n\n"),
        TagEnd::TableHead | TagEnd::TableRow => {}
        TagEnd::TableCell => out.push_str("[/cell]"),
        TagEnd::Emphasis => out.push_str("[/i]"),
        TagEnd::Strong => out.push_str("[/b]"),
        TagEnd::Strikethrough => out.push_str("[/s]"),
        TagEnd::Link => unreachable!("links are handled with state in render_markdown"),
        TagEnd::Image => out.push_str("[/i]"),
        TagEnd::MetadataBlock(_) => {}
        TagEnd::Superscript => out.push_str("[/sup]"),
        TagEnd::Subscript => out.push_str("[/sub]"),
    }
}

fn heading_size(level: HeadingLevel) -> &'static str {
    match level {
        HeadingLevel::H1 => "26",
        HeadingLevel::H2 => "23",
        HeadingLevel::H3 => "20",
        HeadingLevel::H4 => "18",
        HeadingLevel::H5 => "16",
        HeadingLevel::H6 => "14",
    }
}

fn safe_url(url: &str) -> bool {
    (url.starts_with("https://") || url.starts_with("http://") || url.starts_with("mailto:"))
        && !url
            .chars()
            .any(|c| c.is_control() || c.is_whitespace() || matches!(c, '[' | ']' | '"' | '\''))
}

fn escape_bbcode_into(out: &mut String, text: &str) {
    for c in text.chars() {
        if c == '[' {
            out.push_str("[lb]");
        } else {
            out.push(c);
        }
    }
}

fn truncate_utf8(input: &str, max_bytes: usize) -> &str {
    if input.len() <= max_bytes {
        return input;
    }
    let mut end = max_bytes;
    while end > 0 && !input.is_char_boundary(end) {
        end -= 1;
    }
    &input[..end]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_common_markdown() {
        let rendered = render_markdown("# Title\n\n**bold** and `code`").text;
        assert!(rendered.contains("[font_size=26][b]Title[/b][/font_size]"));
        assert!(rendered.contains("[b]bold[/b]"));
        assert!(rendered.contains("[code]code[/code]"));
    }

    #[test]
    fn escapes_raw_bbcode_and_html() {
        let rendered = render_markdown("[color=red]bad[/color]\n\n<script>x</script>").text;
        assert!(!rendered.contains("[color=red]"));
        assert!(rendered.contains("[lb]color=red]"));
        assert!(rendered.contains("<script>x</script>"));
    }

    #[test]
    fn does_not_emit_image_tags_or_unsafe_links() {
        let rendered = render_markdown(
            "![alt](https://example.com/a.png)\n\n[x](javascript:alert(1)) [ok](https://example.com)",
        )
        .text;
        assert!(!rendered.contains("[img"));
        assert!(!rendered.contains("javascript:"));
        assert!(rendered.contains("[url=https://example.com]ok[/url]"));
    }

    #[test]
    fn lists_are_indented_bullets_and_our_own_numbers() {
        // The list *tags* are never emitted (see the module docs: Godot's
        // list layout is superlinear, and the live preview pays it on every
        // update), so the bullet and the number are this renderer's own text.
        // Numbering from the source's own start is a side effect: `[ol]`
        // could not carry a start and rendered `3.` as `1.`.
        let rendered = render_markdown("- one\n- two\n\n3. third\n4. fourth").text;
        assert!(
            !rendered.contains("[ul]") && !rendered.contains("[ol]"),
            "no list tag may be emitted: {rendered}"
        );
        assert!(
            rendered.contains("[indent]• one\n• two\n[/indent]"),
            "{rendered}"
        );
        assert!(
            rendered.contains("[indent]3. third\n4. fourth\n[/indent]"),
            "{rendered}"
        );
    }

    #[test]
    fn a_nested_list_nests_its_indent() {
        let rendered = render_markdown("- outer\n  - inner\n").text;
        assert!(
            rendered.contains("• outer\n[indent]• inner\n[/indent]"),
            "a nested list must open its own indent under its item: {rendered}"
        );
        // A loose item ends its paragraph on a blank line already; the nested
        // list must not add a second one.
        let loose = render_markdown("- outer\n\n  - inner\n").text;
        assert!(
            loose.contains("• outer\n\n[indent]• inner"),
            "a loose item's paragraph already ended the line: {loose}"
        );
        assert!(!loose.contains("\n\n\n"), "no blank line doubled: {loose}");
    }

    #[test]
    fn a_source_at_the_cap_renders_whole_and_a_longer_one_reports_the_cut() {
        let at_cap = "a".repeat(MAX_MARKDOWN_BYTES);
        let rendered = render_markdown(&at_cap);
        assert!(!rendered.truncated, "a source at the cap is not a prefix");
        assert_eq!(rendered.shown, MAX_MARKDOWN_BYTES);
        assert_eq!(rendered.size, MAX_MARKDOWN_BYTES);

        let over = format!("{at_cap}b");
        let rendered = render_markdown(&over);
        assert!(rendered.truncated, "past the cap the render must say so");
        assert_eq!(rendered.shown, MAX_MARKDOWN_BYTES);
        assert_eq!(rendered.size, MAX_MARKDOWN_BYTES + 1);
        assert!(
            !rendered.text.contains('b'),
            "the byte past the cap is not rendered"
        );
    }

    #[test]
    fn a_cut_inside_a_utf8_sequence_drops_the_whole_character() {
        // The cap lands inside the last character, so a byte-wise cut would
        // half-render it: the cut has to move back to the boundary.
        let source = format!("{}é", "a".repeat(MAX_MARKDOWN_BYTES - 1));
        let rendered = render_markdown(&source);
        assert!(rendered.truncated);
        assert_eq!(
            rendered.shown,
            MAX_MARKDOWN_BYTES - 1,
            "the torn tail is not rendered at all"
        );
        assert!(!rendered.text.contains('é'));
    }

    /// The input cap is the read cap the panes already apply, and the two have
    /// to stay one number: a pane that shows a document at its read cap must
    /// render all of it, or its own "showing the first 1 MiB" claim is a lie
    /// about a view that stopped sooner. There is no FFI for a constant, so
    /// this test reads the GDScript declaration instead of restating it.
    #[test]
    fn the_input_cap_is_the_read_cap_the_panes_apply() {
        const TEXT_READ_SRC: &str = include_str!("../../../godot/scenes/panes/text_read.gd");
        let declared = TEXT_READ_SRC
            .lines()
            .find_map(|line| line.trim().strip_prefix("const DEFAULT_MAX_BYTES :="))
            .map(|expr| expr.trim().trim_end_matches(';'))
            .expect("TextRead.DEFAULT_MAX_BYTES must be declared");
        let agrees = declared == "1 << 20"
            || declared
                .parse::<usize>()
                .is_ok_and(|value| value == MAX_MARKDOWN_BYTES);
        assert!(
            agrees,
            "the render cap ({MAX_MARKDOWN_BYTES}) must equal TextRead.DEFAULT_MAX_BYTES ({declared})"
        );
        assert_eq!(
            MAX_MARKDOWN_BYTES,
            gpty_core::vault::MAX_NOTE_BYTES as usize,
            "and the note read cap the same panes read under"
        );
    }

    /// Not an assertion test — a probe. Run
    /// `cargo test -p gpty-gdext --lib probe_render_cost -- --nocapture`
    /// (and again with `--release`) before changing [`MAX_MARKDOWN_BYTES`]:
    /// the cap bounds one GUI-thread call, and the cost is linear in the
    /// source, so the numbers are what a change has to be argued against.
    #[test]
    fn probe_render_cost() {
        let unit = "# Heading\n\nSome **bold** and `code` and a [link](https://example.com/x).\n\n- item one\n- item two\n\n> quoted line\n\n";
        for kib in [256usize, 512, 1024, 2048] {
            let mut src = String::with_capacity(kib * 1024 + unit.len());
            while src.len() < kib * 1024 {
                src.push_str(unit);
            }
            let start = std::time::Instant::now();
            let rendered = render_markdown(&src);
            let elapsed = start.elapsed();
            println!(
                "PROBE {kib} KiB markdown -> {} KiB bbcode in {elapsed:?}",
                rendered.text.len() / 1024
            );
            assert!(!rendered.text.is_empty());
        }
    }
}
