//! Wikilinks: parsing `[[note]]` occurrences out of a note's body, and
//! resolving one against the vault's note set.
//!
//! Pure functions over text and a list of note paths — the store
//! ([`crate::vault`]) owns *when* they run: the index pass already reads every
//! changed note's body to fill `body`/`title`, so a link parse there is ~free,
//! sits in the same transaction as the note row, and cannot drift from the
//! text the FTS index holds.
//!
//! The syntax is the settled subset: `[[target]]`, `[[target|alias]]` (the
//! alias is a display label, never part of the edge), `[[target#heading]]`
//! (the fragment belongs to navigation and is dropped from the edge), and a
//! target containing `/` names a path. One stored row per **occurrence**, so a
//! note mentioning `[[B]]` three times is three rows — a backlink is the same
//! edge read in reverse (`WHERE resolved = ?`), never authored twice. Not every
//! `[[…]]` is an edge: a fenced code block, an inline code span, or a
//! backslash-escaped opener is literal text, because a note documenting the
//! syntax must not create edges.

use std::collections::HashMap;

/// Links kept per note. A note that mentions a target fifty times is a list,
/// not fifty edges; the cap bounds what one note can write (≈1M rows at the
/// 2000-note walk cap) the way the concept engine caps its own parse.
pub const MAX_LINK_OCCURRENCES: usize = 512;

/// Longest target kept, in bytes. A longer one is not a link.
pub const MAX_LINK_TARGET_BYTES: usize = 1024;

/// One `[[…]]` occurrence found in a note's body.
///
/// `alias` and `fragment` are presentation: the store keeps the *edge*
/// (`target`), and a caller that wants to render the mention re-parses the
/// line — nothing outside this module stores them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Link {
    /// 0-based index of the occurrence within the note (the stored identity:
    /// one row per occurrence, `(vault, src, seq)`).
    pub seq: usize,
    /// 1-based line the mention is on.
    pub line: usize,
    /// What the edge points at: alias and fragment stripped.
    pub target: String,
    /// The display label when written (`[[target|alias]]`).
    pub alias: Option<String>,
    /// The heading when written (`[[target#heading]]`), navigation only.
    pub fragment: Option<String>,
}

/// Parse every link occurrence of one note body.
///
/// Line-oriented, so an occurrence carries its line while the body is already
/// in memory. Fenced code blocks (``` / `~~~`, closed by the same character at
/// the same length or longer), inline code spans (a backtick run closed by a
/// run of the same length) and a backslash-escaped opener are skipped — the
/// link *syntax* is documented in notes too. `MAX_LINK_OCCURRENCES` cuts the
/// scan; a target longer than `MAX_LINK_TARGET_BYTES` is not a link.
pub fn parse_links(body: &str) -> Vec<Link> {
    let mut links = Vec::new();
    let mut fence: Option<(u8, usize)> = None;
    for (index, raw) in body.lines().enumerate() {
        let line = raw.trim_end_matches('\r');
        if let Some((marker, length)) = fence {
            if closes_fence(line, marker, length) {
                fence = None;
            }
            continue;
        }
        if let Some(open) = opens_fence(line) {
            fence = Some(open);
            continue;
        }
        scan_line(line, index + 1, &mut links);
        if links.len() >= MAX_LINK_OCCURRENCES {
            links.truncate(MAX_LINK_OCCURRENCES);
            break;
        }
    }
    links
}

/// `(marker, length)` when this line opens a fenced code block.
///
/// CommonMark also cares about indentation and the info string; a note is not
/// a conformance suite, so a run of three or more backticks or tildes at the
/// start of a line is a fence.
fn opens_fence(line: &str) -> Option<(u8, usize)> {
    let marker = *line.trim_start().as_bytes().first()?;
    if marker != b'`' && marker != b'~' {
        return None;
    }
    let run = run_length(line.trim_start().as_bytes(), 0, marker);
    (run >= 3).then_some((marker, run))
}

/// Whether this line closes a fence opened with `marker` × `length`.
fn closes_fence(line: &str, marker: u8, length: usize) -> bool {
    let t = line.trim();
    !t.is_empty() && t.bytes().all(|b| b == marker) && t.len() >= length
}

/// The length of the run of `marker` starting at `start`.
fn run_length(bytes: &[u8], start: usize, marker: u8) -> usize {
    let mut n = 0;
    while bytes.get(start + n) == Some(&marker) {
        n += 1;
    }
    n
}

/// Find links on one line, skipping inline code spans.
///
/// Byte scanning is safe here: every delimiter this looks for is ASCII, so an
/// index at one is always a char boundary.
fn scan_line(line: &str, number: usize, out: &mut Vec<Link>) {
    let bytes = line.as_bytes();
    let mut i = 0;
    let mut code_run: Option<usize> = None;
    while i < bytes.len() {
        if bytes[i] == b'`' {
            let run = run_length(bytes, i, b'`');
            if code_run == Some(run) {
                code_run = None;
            } else if code_run.is_none() {
                code_run = Some(run);
            }
            i += run;
            continue;
        }
        if code_run.is_none()
            && bytes[i] == b'['
            && bytes.get(i + 1) == Some(&b'[')
            && !is_escaped(bytes, i)
            && let Some(close) = find_close(bytes, i + 2)
        {
            if let Some(link) = link_from(&line[i + 2..close], number, out.len()) {
                out.push(link);
            }
            i = close + 2;
            continue;
        }
        i += 1;
    }
}

/// The index of the `]]` closing an opener at `from`, if this is a link at all.
///
/// A target may not contain `[` — nested brackets are not syntax — and the
/// first `]]` wins, so the scan resumes after it either way.
fn find_close(bytes: &[u8], from: usize) -> Option<usize> {
    let mut i = from;
    while i + 1 < bytes.len() {
        match bytes[i] {
            b'[' => return None,
            b']' if bytes[i + 1] == b']' => return Some(i),
            _ => {}
        }
        i += 1;
    }
    None
}

/// Whether the byte at `at` is escaped by an odd run of backslashes.
fn is_escaped(bytes: &[u8], at: usize) -> bool {
    let mut backslashes = 0;
    let mut i = at;
    while i > 0 && bytes[i - 1] == b'\\' {
        backslashes += 1;
        i -= 1;
    }
    backslashes % 2 == 1
}

/// One occurrence's content (`target`, optionally `|alias`, optionally
/// `#heading`) as a [`Link`], or `None` when it is not a link.
fn link_from(content: &str, line: usize, seq: usize) -> Option<Link> {
    let (left, alias) = match content.split_once('|') {
        Some((left, alias)) => (left, Some(alias)),
        None => (content, None),
    };
    let (target, fragment) = match left.split_once('#') {
        Some((target, fragment)) => (target, Some(fragment)),
        None => (left, None),
    };
    if target.is_empty() || target.len() > MAX_LINK_TARGET_BYTES {
        return None;
    }
    let not_empty = |s: &&str| !s.is_empty();
    Some(Link {
        seq,
        line,
        target: target.to_string(),
        alias: alias.filter(not_empty).map(str::to_string),
        fragment: fragment.filter(not_empty).map(str::to_string),
    })
}

/// How a target resolved against the notes a vault holds.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Resolution {
    /// Exactly one note matched.
    Resolved(String),
    /// Several notes matched, so none was picked — a stem two notes share is
    /// never silently resolved. Sorted, so the hint is deterministic.
    Ambiguous(Vec<String>),
    /// Nothing matched.
    Missing,
}

impl Resolution {
    /// The note this resolved to, if any — what the store writes (a
    /// `resolved` column stays NULL for both unresolved cases, and the
    /// difference between them is the hint the query derives).
    pub fn note(&self) -> Option<&str> {
        match self {
            Resolution::Resolved(note) => Some(note),
            Resolution::Ambiguous(_) | Resolution::Missing => None,
        }
    }
}

/// The note set of one vault, indexed for [`NoteIndex::resolve`].
///
/// Built once per pass (or per query) so resolving many targets is a hash
/// lookup each rather than a scan; the rules are the settled ones — a target
/// with `/` names a path (`note` matches `note.md`), a bare target names a
/// file stem, exact case first and a *unique* case-insensitive match second,
/// and more than one match at either stage is ambiguous.
pub struct NoteIndex<'a> {
    paths: HashMap<&'a str, &'a str>,
    paths_ci: HashMap<String, Vec<&'a str>>,
    stems: HashMap<&'a str, Vec<&'a str>>,
    stems_ci: HashMap<String, Vec<&'a str>>,
}

impl<'a> NoteIndex<'a> {
    pub fn new(notes: &[&'a str]) -> Self {
        let mut index = Self {
            paths: HashMap::new(),
            paths_ci: HashMap::new(),
            stems: HashMap::new(),
            stems_ci: HashMap::new(),
        };
        for note in notes {
            index.paths.insert(note, note);
            index
                .paths_ci
                .entry(note.to_lowercase())
                .or_default()
                .push(note);
            let stem = note_stem(note);
            index.stems.entry(stem).or_default().push(note);
            index
                .stems_ci
                .entry(stem.to_lowercase())
                .or_default()
                .push(note);
        }
        index
    }

    /// Resolve one target against the note set.
    pub fn resolve(&self, target: &str) -> Resolution {
        let (exact, ci) = if target.contains('/') {
            let path = if target.ends_with(".md") {
                target.to_string()
            } else {
                format!("{target}.md")
            };
            (
                self.paths.get(path.as_str()).copied(),
                self.paths_ci.get(&path.to_lowercase()),
            )
        } else {
            (
                self.stems.get(target).and_then(|v| single(v)),
                self.stems_ci.get(&target.to_lowercase()),
            )
        };
        if let Some(note) = exact {
            return Resolution::Resolved(note.to_string());
        }
        match ci {
            None => Resolution::Missing,
            Some(matches) => match single(matches) {
                Some(note) => Resolution::Resolved(note.to_string()),
                None => Resolution::Ambiguous(sorted(matches)),
            },
        }
    }
}

/// The one element of a bucket, or `None` when the bucket is not a single
/// element (empty or ambiguous).
fn single<'a>(matches: &[&'a str]) -> Option<&'a str> {
    match matches {
        [only] => Some(*only),
        _ => None,
    }
}

fn sorted(matches: &[&str]) -> Vec<String> {
    let mut out: Vec<String> = matches.iter().map(|s| s.to_string()).collect();
    out.sort();
    out
}

/// A note's file stem, the name a bare target matches.
fn note_stem(rel_path: &str) -> &str {
    rel_path
        .rsplit('/')
        .next()
        .unwrap_or(rel_path)
        .strip_suffix(".md")
        .unwrap_or(rel_path)
}

/// [`NoteIndex::resolve`] for a single target — the convenience the tests and
/// one-off callers want.
pub fn resolve_target(target: &str, notes: &[&str]) -> Resolution {
    NoteIndex::new(notes).resolve(target)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn targets(body: &str) -> Vec<(usize, usize, String)> {
        parse_links(body)
            .into_iter()
            .map(|l| (l.line, l.seq, l.target))
            .collect()
    }

    #[test]
    fn parses_targets_aliases_and_fragments() {
        let links =
            parse_links("See [[Other]] and [[dir/Note.md|The label]] and [[Target#Heading]].");
        assert_eq!(links.len(), 3);
        assert_eq!(links[0].target, "Other");
        assert_eq!(links[0].alias, None);
        assert_eq!(links[0].fragment, None);
        assert_eq!(links[1].target, "dir/Note.md");
        assert_eq!(links[1].alias.as_deref(), Some("The label"));
        assert_eq!(links[2].target, "Target", "the fragment is not the edge");
        assert_eq!(links[2].fragment.as_deref(), Some("Heading"));
    }

    #[test]
    fn one_row_per_occurrence_with_its_line_and_sequence() {
        let links = parse_links("[[a]]\n\ntext [[b|B]] and [[a]] again\n[[c]]");
        assert_eq!(
            targets("[[a]]\n\ntext [[b|B]] and [[a]] again\n[[c]]"),
            vec![
                (1, 0, "a".to_string()),
                (3, 1, "b".to_string()),
                (3, 2, "a".to_string()),
                (4, 3, "c".to_string()),
            ]
        );
        assert_eq!(links[2].target, "a", "the same target twice is two rows");
    }

    #[test]
    fn code_is_literal_text() {
        // Fenced blocks, inline spans (including a mismatched run that does not
        // close) and escaped openers all keep the syntax from becoming an edge.
        let body = "\
```\n[[fenced]]\n```\n\
~~~\n[[tilde fenced]]\n~~~\n\
inline `[[span]]` and ``[[double]]`` stay literal\n\
escaped \\[[not a link]] and a real one [[yes]]\n\
a `[[span]]` then a real [[after]]\n\
\\\\[[escaped backslash then real]]\n";
        assert_eq!(
            targets(body),
            vec![
                (8, 0, "yes".to_string()),
                (9, 1, "after".to_string()),
                (10, 2, "escaped backslash then real".to_string()),
            ]
        );
    }

    #[test]
    fn a_fence_survives_until_it_closes() {
        let body = "\
```\n[[a]]\n````\n\
[[b]]\n\
~~~~\n[[c]]\n\
```\n\
~~~\n\
~~~~\n\
[[d]]\n";
        assert_eq!(
            targets(body),
            vec![(4, 0, "b".to_string()), (10, 1, "d".to_string())],
            "a longer run closes it; a different marker and a shorter run do not"
        );
    }

    #[test]
    fn rejects_what_is_not_a_link() {
        assert!(parse_links("[[unclosed").is_empty());
        assert!(
            parse_links("[[]]").is_empty(),
            "an empty target is not an edge"
        );
        assert!(
            parse_links("[[a[b]]").is_empty(),
            "nested brackets are not syntax"
        );
        assert!(
            parse_links("[[|alias]]").is_empty(),
            "an empty target is not an edge, whatever the alias says"
        );
        assert_eq!(
            parse_links("[[a|]]")[0].target,
            "a",
            "an empty alias still links to its target"
        );
        let long = "x".repeat(MAX_LINK_TARGET_BYTES + 1);
        assert!(
            parse_links(&format!("[[{long}]]")).is_empty(),
            "a target has a cap"
        );
        assert_eq!(
            parse_links(&format!("[[{}]]", "x".repeat(MAX_LINK_TARGET_BYTES))).len(),
            1
        );
    }

    #[test]
    fn the_occurrence_cap_bounds_one_note() {
        let body = "[[a]] ".repeat(MAX_LINK_OCCURRENCES + 50);
        let links = parse_links(&body);
        assert_eq!(links.len(), MAX_LINK_OCCURRENCES);
        assert_eq!(links.last().unwrap().seq, MAX_LINK_OCCURRENCES - 1);
    }

    #[test]
    fn a_bare_target_resolves_by_stem() {
        let notes = ["note.md", "sub/other.md"];
        assert_eq!(
            resolve_target("note", &notes),
            Resolution::Resolved("note.md".into())
        );
        assert_eq!(
            resolve_target("other", &notes),
            Resolution::Resolved("sub/other.md".into()),
            "the stem is the file name, not the path"
        );
        assert_eq!(resolve_target("missing", &notes), Resolution::Missing);
    }

    #[test]
    fn a_slash_target_resolves_by_path() {
        let notes = ["sub/other.md", "note.md"];
        assert_eq!(
            resolve_target("sub/other", &notes),
            Resolution::Resolved("sub/other.md".into()),
            "the extension is optional"
        );
        assert_eq!(
            resolve_target("sub/other.md", &notes),
            Resolution::Resolved("sub/other.md".into())
        );
        assert_eq!(
            resolve_target("other.md", &notes),
            Resolution::Missing,
            "a path needs its directory"
        );
    }

    #[test]
    fn case_matches_exactly_first_then_uniquely() {
        let notes = ["Note.md"];
        assert_eq!(
            resolve_target("note", &notes),
            Resolution::Resolved("Note.md".into()),
            "a unique case-insensitive match resolves"
        );
        assert_eq!(
            resolve_target("Note", &notes),
            Resolution::Resolved("Note.md".into())
        );
        let both = ["Note.md", "note.md"];
        assert_eq!(
            resolve_target("note", &both),
            Resolution::Resolved("note.md".into()),
            "an exact match wins even when a case variant exists"
        );
    }

    #[test]
    fn a_shared_stem_or_a_case_clash_is_ambiguous() {
        let shared = ["a/note.md", "b/note.md"];
        assert_eq!(
            resolve_target("note", &shared),
            Resolution::Ambiguous(vec!["a/note.md".into(), "b/note.md".into()]),
            "a stem two notes share is never silently picked"
        );
        let clash = ["Note.md", "note.md"];
        assert_eq!(
            resolve_target("NOTE", &clash),
            Resolution::Ambiguous(vec!["Note.md".into(), "note.md".into()])
        );
    }

    #[test]
    fn a_path_is_not_a_stem() {
        let notes = ["sub/note.md"];
        assert_eq!(
            resolve_target("sub/note", &notes),
            Resolution::Resolved("sub/note.md".into())
        );
        assert_eq!(
            resolve_target("note", &notes),
            Resolution::Resolved("sub/note.md".into()),
            "a bare target looks at stems anywhere in the vault"
        );
    }
}
