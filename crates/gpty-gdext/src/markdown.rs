//! Safe CommonMark/GFM subset rendered as Godot `RichTextLabel` BBCode.
//!
//! Markdown is untrusted model/file content. Raw HTML and BBCode are escaped,
//! images are reduced to alt text, and only conservative URL metadata is
//! emitted. `RichTextLabel` never receives source-controlled BBCode tags.

use godot::prelude::*;
use pulldown_cmark::{CodeBlockKind, Event, HeadingLevel, Options, Parser, Tag, TagEnd};

const MAX_MARKDOWN_BYTES: usize = 512 * 1024;

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
    /// Convert untrusted Markdown to sanitized `RichTextLabel` BBCode.
    #[func]
    fn render(&self, markdown: GString) -> GString {
        GString::from(&render_markdown(&markdown.to_string()))
    }
}

fn render_markdown(markdown: &str) -> String {
    let markdown = truncate_utf8(markdown, MAX_MARKDOWN_BYTES);
    let mut options = Options::empty();
    options.insert(Options::ENABLE_STRIKETHROUGH);
    options.insert(Options::ENABLE_TABLES);
    options.insert(Options::ENABLE_TASKLISTS);
    options.insert(Options::ENABLE_GFM);

    let mut out = String::with_capacity(markdown.len() + markdown.len() / 4);
    let mut safe_links = Vec::new();
    for event in Parser::new_ext(markdown, options) {
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
            Event::Start(tag) => start_tag(&mut out, tag),
            Event::End(tag) => end_tag(&mut out, tag),
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
    out
}

fn start_tag(out: &mut String, tag: Tag<'_>) {
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
            // Godot 4.7 BBCode has no [ol start=N] param; the unknown param
            // would render as literal text. Plain [ol] keeps lists valid.
            if start.is_some() {
                out.push_str("[ol]");
            } else {
                out.push_str("[ul]");
            }
        }
        Tag::Item => {}
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

fn end_tag(out: &mut String, tag: TagEnd) {
    match tag {
        TagEnd::Paragraph => out.push_str("\n\n"),
        TagEnd::Heading(_) => out.push_str("[/b][/font_size]\n"),
        TagEnd::BlockQuote(_) => out.push_str("[/indent]\n"),
        TagEnd::CodeBlock => out.push_str("[/code]\n\n"),
        TagEnd::HtmlBlock => {}
        TagEnd::List(ordered) => {
            out.push_str(if ordered { "[/ol]\n" } else { "[/ul]\n" });
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
        let rendered = render_markdown("# Title\n\n**bold** and `code`");
        assert!(rendered.contains("[font_size=26][b]Title[/b][/font_size]"));
        assert!(rendered.contains("[b]bold[/b]"));
        assert!(rendered.contains("[code]code[/code]"));
    }

    #[test]
    fn escapes_raw_bbcode_and_html() {
        let rendered = render_markdown("[color=red]bad[/color]\n\n<script>x</script>");
        assert!(!rendered.contains("[color=red]"));
        assert!(rendered.contains("[lb]color=red]"));
        assert!(rendered.contains("<script>x</script>"));
    }

    #[test]
    fn does_not_emit_image_tags_or_unsafe_links() {
        let rendered = render_markdown(
            "![alt](https://example.com/a.png)\n\n[x](javascript:alert(1)) [ok](https://example.com)",
        );
        assert!(!rendered.contains("[img"));
        assert!(!rendered.contains("javascript:"));
        assert!(rendered.contains("[url=https://example.com]ok[/url]"));
    }

    #[test]
    fn ordered_lists_emit_plain_ol_tag() {
        let rendered = render_markdown("3. third\n4. fourth");
        assert!(rendered.contains("[ol]"));
        assert!(!rendered.contains("start="));
    }
}
