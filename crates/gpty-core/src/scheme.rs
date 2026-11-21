//! Colour-scheme import: one validated [`Scheme`] from a native, Alacritty,
//! iTerm2, Base16 or legacy CSV file.
//!
//! A scheme is **untrusted file input**: the user points the picker at anything
//! on disk. Every parser here is therefore strict and bounded - the text is
//! capped at [`MAX_SCHEME_BYTES`], the native format has a closed key set, the
//! YAML reader accepts a block-mapping subset only, and the iTerm2 reader
//! refuses DOCTYPEs, CDATA and unknown entities rather than resolving them.
//! Errors are one user-facing sentence: the picker shows them verbatim.
//!
//! The format is sniffed from the content, never from the file name (a
//! misnamed file still imports); the name is only a fallback label. Six keys
//! come out of every format - the 16 ANSI entries plus foreground, background,
//! cursor and selection - so the renderer never has to know where they came
//! from. [`to_native_json`] writes that same shape back, which is why an
//! import, a shipped file and a hand edit all read as one format.

use std::collections::BTreeMap;

use serde_json::Value as Json;

use crate::color::SYSTEM_COLORS;

/// Longest scheme text parsed. A palette is 16 short hex colours; anything
/// past this is not a scheme, and the parse runs on the GUI thread.
pub const MAX_SCHEME_BYTES: usize = 16 * 1024;
/// Longest display name kept. A name is a label in a dropdown, not content.
pub const MAX_NAME_CHARS: usize = 64;
/// Every scheme answers this many ANSI entries.
pub const PALETTE_LEN: usize = 16;

const NOT_A_SCHEME: &str = "This file is not an Alacritty, iTerm2, Base16 or gPTY colour scheme.";
const TOO_LARGE: &str = "The file is larger than 16 KiB.";

/// One complete terminal colour scheme.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Scheme {
    pub name: String,
    pub palette: [[u8; 3]; 16],
    pub foreground: [u8; 3],
    pub background: [u8; 3],
    pub cursor: [u8; 3],
    pub selection: [u8; 3],
}

/// Parse one scheme file. `file_name` is a label fallback only; the format is
/// sniffed from `text`.
pub fn parse_scheme(text: &str, file_name: &str) -> Result<Scheme, String> {
    if text.len() > MAX_SCHEME_BYTES {
        return Err(TOO_LARGE.to_string());
    }
    let stem = file_stem(file_name);
    let trimmed = text.trim_start_matches('\u{feff}').trim_start();

    if trimmed.starts_with('<') && text.contains("<plist") {
        return parse_iterm_plist(text, stem);
    }
    if trimmed.starts_with('{') {
        let json: Json = serde_json::from_str(trimmed)
            .map_err(|_| "The scheme JSON is malformed.".to_string())?;
        return parse_native_json(&json, stem);
    }
    if has_base16_key(text) {
        let yaml = parse_yaml_subset(text)?;
        return parse_base16(&yaml, stem);
    }
    if let Ok(doc) = toml::from_str::<toml::Value>(text)
        && doc.get("colors").is_some_and(toml::Value::is_table)
    {
        return parse_alacritty_toml(&doc, stem);
    }
    if let Ok(yaml) = parse_yaml_subset(text)
        && yaml_get(&yaml, &["colors"]).is_some()
    {
        return parse_alacritty_yaml(&yaml, stem);
    }
    let legacy = legacy_tokens(text);
    if !legacy.is_empty() {
        let mut palette = SYSTEM_COLORS;
        for (slot, colour) in legacy.iter().enumerate().take(PALETTE_LEN) {
            palette[slot] = *colour;
        }
        return Ok(Scheme {
            name: sanitize_name(stem),
            palette,
            background: palette[0],
            foreground: palette[7],
            cursor: palette[7],
            selection: palette[8],
        });
    }
    Err(NOT_A_SCHEME.to_string())
}

/// The canonical native file text: the six-key shape, `#rrggbb` strings,
/// pretty-printed with a trailing newline.
pub fn to_native_json(scheme: &Scheme) -> String {
    let palette: Vec<String> = scheme.palette.iter().map(|c| hex(*c)).collect();
    let value = serde_json::json!({
        "name": scheme.name,
        "palette": palette,
        "foreground": hex(scheme.foreground),
        "background": hex(scheme.background),
        "cursor": hex(scheme.cursor),
        "selection": hex(scheme.selection),
    });
    let mut out = serde_json::to_string_pretty(&value).unwrap_or_default();
    out.push('\n');
    out
}

/// A display name from untrusted text: control characters dropped, whitespace
/// collapsed, trimmed, at most [`MAX_NAME_CHARS`] characters. Empty becomes
/// `"Scheme"`.
pub fn sanitize_name(raw: &str) -> String {
    let mut out = String::new();
    let mut taken = 0usize;
    let mut pending_space = false;
    for ch in raw.chars() {
        if ch.is_whitespace() {
            pending_space = !out.is_empty();
            continue;
        }
        if ch.is_control() {
            continue;
        }
        if pending_space {
            out.push(' ');
            taken += 1;
            pending_space = false;
        }
        if taken >= MAX_NAME_CHARS {
            break;
        }
        out.push(ch);
        taken += 1;
    }
    let trimmed = out.trim();
    if trimmed.is_empty() {
        "Scheme".to_string()
    } else {
        trimmed.to_string()
    }
}

fn hex(colour: [u8; 3]) -> String {
    format!("#{:02x}{:02x}{:02x}", colour[0], colour[1], colour[2])
}

fn file_stem(file_name: &str) -> &str {
    std::path::Path::new(file_name)
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("")
}

/// `#rrggbb`, `0xrrggbb` or `rrggbb`, case-insensitive.
fn parse_hex(raw: &str) -> Option<[u8; 3]> {
    let s = raw.trim();
    let body = s
        .strip_prefix('#')
        .or_else(|| s.strip_prefix("0x"))
        .or_else(|| s.strip_prefix("0X"))
        .unwrap_or(s);
    if body.len() != 6 || !body.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let r = u8::from_str_radix(&body[0..2], 16).ok()?;
    let g = u8::from_str_radix(&body[2..4], 16).ok()?;
    let b = u8::from_str_radix(&body[4..6], 16).ok()?;
    Some([r, g, b])
}

fn has_base16_key(text: &str) -> bool {
    text.lines().any(|line| {
        let trimmed = line.trim();
        match trimmed.strip_prefix("base00") {
            Some(rest) => rest.trim_start().starts_with(':'),
            None => false,
        }
    })
}

fn legacy_tokens(text: &str) -> Vec<[u8; 3]> {
    let mut out = Vec::new();
    for token in text.split([',', '\n', '\r', '\t', ' ']) {
        let token = token.trim();
        if token.is_empty() {
            continue;
        }
        match parse_hex(token) {
            Some(colour) => out.push(colour),
            // One non-colour token means this is not a legacy CSV at all.
            None => return Vec::new(),
        }
    }
    out
}

// ═══════════════════════════════════════════════════════════════════════
// Native JSON
// ═══════════════════════════════════════════════════════════════════════

const NATIVE_KEYS: [&str; 6] = [
    "name",
    "palette",
    "foreground",
    "background",
    "cursor",
    "selection",
];

fn parse_native_json(json: &Json, stem: &str) -> Result<Scheme, String> {
    let object = json
        .as_object()
        .ok_or_else(|| "A scheme must be a JSON object.".to_string())?;
    for key in object.keys() {
        if !NATIVE_KEYS.contains(&key.as_str()) {
            return Err(format!(
                "Unknown key \"{key}\"; expected name, palette, foreground, background, cursor or selection."
            ));
        }
    }

    let entries = object
        .get("palette")
        .and_then(Json::as_array)
        .ok_or_else(|| "A scheme needs a \"palette\" array.".to_string())?;
    if entries.len() != PALETTE_LEN {
        return Err(format!(
            "palette must list exactly 16 colours (found {}).",
            entries.len()
        ));
    }
    let mut palette = SYSTEM_COLORS;
    for (slot, entry) in entries.iter().enumerate() {
        let raw = entry
            .as_str()
            .ok_or_else(|| format!("palette[{slot}] is not a #rrggbb colour."))?;
        palette[slot] =
            parse_hex(raw).ok_or_else(|| format!("palette[{slot}] is not a #rrggbb colour."))?;
    }

    let required = |key: &str| -> Result<[u8; 3], String> {
        let raw = object
            .get(key)
            .and_then(Json::as_str)
            .ok_or_else(|| format!("\"{key}\" must be a #rrggbb colour."))?;
        parse_hex(raw).ok_or_else(|| format!("\"{key}\" must be a #rrggbb colour."))
    };
    let foreground = required("foreground")?;
    let background = required("background")?;
    let optional = |key: &str| -> Option<[u8; 3]> {
        object.get(key).and_then(Json::as_str).and_then(parse_hex)
    };
    let cursor = optional("cursor").unwrap_or(foreground);
    let selection = optional("selection").unwrap_or(palette[8]);
    let name = match object.get("name").and_then(Json::as_str) {
        Some(raw) => sanitize_name(raw),
        None => sanitize_name(stem),
    };

    Ok(Scheme {
        name,
        palette,
        foreground,
        background,
        cursor,
        selection,
    })
}

// ═══════════════════════════════════════════════════════════════════════
// Base16 and Alacritty YAML
// ═══════════════════════════════════════════════════════════════════════

#[derive(Clone, Debug)]
enum Yaml {
    Scalar(String),
    Map(BTreeMap<String, Yaml>),
}

struct YamlLine<'a> {
    indent: usize,
    content: &'a str,
}

fn parse_yaml_subset(text: &str) -> Result<Yaml, String> {
    let text = text.trim_start_matches('\u{feff}');
    let mut lines: Vec<YamlLine<'_>> = Vec::new();
    for raw in text.lines() {
        let raw = raw.strip_suffix('\r').unwrap_or(raw);
        if raw.starts_with('\t') {
            return Err("YAML indentation must use spaces.".to_string());
        }
        let trimmed = raw.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') || trimmed == "---" || trimmed == "..." {
            continue;
        }
        let indent = raw.len() - raw.trim_start_matches(' ').len();
        let content = raw.trim_start_matches(' ');
        if content.contains('\t') {
            return Err("YAML indentation must use spaces.".to_string());
        }
        if indent > 0 && lines.is_empty() {
            return Err(format!("Unsupported YAML line: {}", clamp_line(content)));
        }
        lines.push(YamlLine { indent, content });
    }
    if lines.is_empty() {
        return Err(NOT_A_SCHEME.to_string());
    }
    let mut index = 0usize;
    let map = parse_yaml_block(&lines, &mut index, 0)?;
    if index < lines.len() {
        return Err(format!(
            "Unexpected indentation at: {}",
            clamp_line(lines[index].content)
        ));
    }
    Ok(Yaml::Map(map))
}

fn clamp_line(line: &str) -> String {
    let mut out: String = line.chars().take(80).collect();
    if line.chars().count() > 80 {
        out.push('…');
    }
    out
}

fn parse_yaml_block(
    lines: &[YamlLine<'_>],
    index: &mut usize,
    indent: usize,
) -> Result<BTreeMap<String, Yaml>, String> {
    let mut map = BTreeMap::new();
    while *index < lines.len() && lines[*index].indent == indent {
        let line = &lines[*index];
        let (key, rest) = split_yaml_key(line.content)?;
        *index += 1;
        if rest.is_empty() {
            if *index >= lines.len() || lines[*index].indent <= indent {
                return Err(format!("\"{key}\" needs a nested block."));
            }
            let child_indent = lines[*index].indent;
            let child = parse_yaml_block(lines, index, child_indent)?;
            if map.insert(key.clone(), Yaml::Map(child)).is_some() {
                return Err(format!("Duplicate YAML key \"{key}\"."));
            }
        } else {
            let value = yaml_scalar(rest)?;
            if map.insert(key.clone(), Yaml::Scalar(value)).is_some() {
                return Err(format!("Duplicate YAML key \"{key}\"."));
            }
        }
    }
    if *index < lines.len() && lines[*index].indent > indent {
        return Err(format!(
            "Unexpected indentation at: {}",
            clamp_line(lines[*index].content)
        ));
    }
    Ok(map)
}

fn split_yaml_key(content: &str) -> Result<(String, &str), String> {
    let colon = content
        .find(':')
        .ok_or_else(|| format!("Unsupported YAML line: {}", clamp_line(content)))?;
    let key = content[..colon].trim();
    if key.is_empty()
        || !key
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b'-'))
    {
        return Err(format!("Unsupported YAML line: {}", clamp_line(content)));
    }
    Ok((key.to_string(), content[colon + 1..].trim()))
}

fn yaml_scalar(raw: &str) -> Result<String, String> {
    let raw = raw.trim();
    if raw.is_empty() {
        return Ok(String::new());
    }
    let first = raw.chars().next().unwrap_or(' ');
    if matches!(
        first,
        '{' | '[' | '&' | '*' | '!' | '|' | '>' | '@' | '`' | '-'
    ) {
        return Err(format!("Unsupported YAML value: {}", clamp_line(raw)));
    }
    if (first == '"' || first == '\'') && raw.len() >= 2 && raw.ends_with(first) {
        return Ok(raw[1..raw.len() - 1].to_string());
    }
    // An unquoted scalar loses a trailing comment.
    let without_comment = match raw.find(" #") {
        Some(at) => raw[..at].trim(),
        None => raw,
    };
    Ok(without_comment.to_string())
}

fn yaml_get<'a>(node: &'a Yaml, path: &[&str]) -> Option<&'a Yaml> {
    let mut current = node;
    for key in path {
        let Yaml::Map(map) = current else {
            return None;
        };
        current = map.get(*key)?;
    }
    Some(current)
}

fn yaml_scalar_at<'a>(root: &'a Yaml, path: &[&str]) -> Option<&'a str> {
    match yaml_get(root, path)? {
        Yaml::Scalar(value) => Some(value.as_str()),
        Yaml::Map(_) => None,
    }
}

fn base16_lookup<'a>(root: &'a Yaml, key: &str) -> Option<&'a str> {
    let Yaml::Map(map) = root else {
        return None;
    };
    let wanted = key.to_ascii_lowercase();
    map.iter()
        .find(|(name, _)| name.to_ascii_lowercase() == wanted)
        .and_then(|(_, value)| match value {
            Yaml::Scalar(text) => Some(text.as_str()),
            Yaml::Map(_) => None,
        })
}

fn parse_base16(root: &Yaml, stem: &str) -> Result<Scheme, String> {
    let mut bases = [[0u8; 3]; 16];
    for (slot, entry) in bases.iter_mut().enumerate() {
        let key = format!("base{slot:02X}");
        let raw = base16_lookup(root, &key)
            .ok_or_else(|| format!("The Base16 scheme is missing \"{key}\"."))?;
        *entry = parse_hex(raw).ok_or_else(|| format!("\"{key}\" is not a #rrggbb colour."))?;
    }
    // The base16-shell mapping: these indices are what every base16 terminal
    // template sets, so a palette renders the same here as it does elsewhere.
    const ORDER: [usize; 16] = [0, 8, 11, 10, 13, 14, 12, 5, 3, 9, 1, 2, 4, 6, 15, 7];
    let mut palette = SYSTEM_COLORS;
    for (slot, base) in ORDER.iter().enumerate() {
        palette[slot] = bases[*base];
    }
    let name = match base16_lookup(root, "scheme") {
        Some(raw) => sanitize_name(raw),
        None => sanitize_name(stem),
    };
    Ok(Scheme {
        name,
        palette,
        background: bases[0],
        foreground: bases[5],
        cursor: bases[5],
        selection: bases[2],
    })
}

fn parse_alacritty_yaml(root: &Yaml, stem: &str) -> Result<Scheme, String> {
    parse_alacritty_parts(stem, |path: &[&str]| {
        yaml_scalar_at(root, path).map(|s| s.to_string())
    })
}

// ═══════════════════════════════════════════════════════════════════════
// Alacritty TOML
// ═══════════════════════════════════════════════════════════════════════

fn parse_alacritty_toml(doc: &toml::Value, stem: &str) -> Result<Scheme, String> {
    parse_alacritty_parts(stem, |path: &[&str]| {
        let mut current = doc;
        for key in path {
            current = current.get(*key)?;
        }
        current.as_str().map(|s| s.to_string())
    })
}

const ANSI_NAMES: [&str; 8] = [
    "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
];

/// The key walk both Alacritty formats share. `get` answers the dotted path's
/// string value, so a TOML table and the YAML subset feed the same rules.
fn parse_alacritty_parts(
    stem: &str,
    get: impl Fn(&[&str]) -> Option<String>,
) -> Result<Scheme, String> {
    let mut palette = SYSTEM_COLORS;
    for (index, name) in ANSI_NAMES.iter().enumerate() {
        let path = ["colors", "normal", *name];
        palette[index] = alacritty_colour(&get, &path)?;
        let path = ["colors", "bright", *name];
        palette[index + 8] = alacritty_colour(&get, &path)?;
    }
    let background = alacritty_colour(&get, &["colors", "primary", "background"])?;
    let foreground = alacritty_colour(&get, &["colors", "primary", "foreground"])?;
    let cursor = match get(&["colors", "cursor", "cursor"]) {
        Some(raw) => parse_hex(&raw)
            .ok_or_else(|| "\"colors.cursor.cursor\" is not a #rrggbb colour.".to_string())?,
        None => foreground,
    };
    let selection = match get(&["colors", "selection", "background"]) {
        Some(raw) => parse_hex(&raw).ok_or_else(|| {
            "\"colors.selection.background\" is not a #rrggbb colour.".to_string()
        })?,
        None => palette[8],
    };
    Ok(Scheme {
        name: sanitize_name(stem),
        palette,
        foreground,
        background,
        cursor,
        selection,
    })
}

fn alacritty_colour(
    get: &impl Fn(&[&str]) -> Option<String>,
    path: &[&str],
) -> Result<[u8; 3], String> {
    let dotted = path.join(".");
    let raw = get(path).ok_or_else(|| format!("The scheme is missing \"{dotted}\"."))?;
    parse_hex(&raw).ok_or_else(|| format!("\"{dotted}\" is not a #rrggbb colour."))
}

// ═══════════════════════════════════════════════════════════════════════
// iTerm2 XML plist
// ═══════════════════════════════════════════════════════════════════════

#[derive(Clone, Debug)]
enum Plist {
    Dict(BTreeMap<String, Plist>),
    Real(f64),
    Int(i64),
    Str,
    Bool(bool),
}

const XML_DEPTH_CAP: usize = 4;
const XML_ENTITY_ERROR: &str = "A DOCTYPE or entity reference is not allowed in an iTerm2 scheme.";

struct XmlReader<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl<'a> XmlReader<'a> {
    fn new(text: &'a str) -> Self {
        let bytes = text.as_bytes();
        let mut at = 0usize;
        if bytes.starts_with(&[0xEF, 0xBB, 0xBF]) {
            at = 3;
        }
        Self { bytes, at }
    }

    fn rest(&self) -> &'a [u8] {
        &self.bytes[self.at..]
    }

    fn starts_with(&self, lit: &[u8]) -> bool {
        self.rest().starts_with(lit)
    }

    fn expect(&mut self, lit: &str) -> Result<(), String> {
        if self.starts_with(lit.as_bytes()) {
            self.at += lit.len();
            Ok(())
        } else {
            Err(format!("iTerm2 plist: expected \"{lit}\"."))
        }
    }

    /// Whitespace, the XML declaration, a plain DOCTYPE and comments, in any
    /// order. Every real `.itermcolors` starts with `<?xml …?>` and
    /// `<!DOCTYPE plist PUBLIC …>`, so those two are accepted - but nothing
    /// they could declare is ever resolved: an internal subset (`[ … ]`, where
    /// entities are defined) is refused, as is any other `<!` (CDATA, a
    /// processing instruction other than the XML declaration).
    fn skip_misc(&mut self) -> Result<(), String> {
        loop {
            let rest = self.rest();
            let skipped = rest.iter().take_while(|b| b.is_ascii_whitespace()).count();
            self.at += skipped;
            if self.starts_with(b"<!--") {
                let rest = self.rest();
                let end = rest
                    .windows(3)
                    .position(|w| w == b"-->")
                    .ok_or_else(|| "iTerm2 plist: unterminated comment.".to_string())?;
                self.at += end + 3;
                continue;
            }
            if self.starts_with(b"<?") {
                let rest = self.rest();
                let end = rest
                    .windows(2)
                    .position(|w| w == b"?>")
                    .ok_or_else(|| "iTerm2 plist: unterminated declaration.".to_string())?;
                self.at += end + 2;
                continue;
            }
            if self.starts_with(b"<!DOCTYPE") {
                self.skip_doctype()?;
                continue;
            }
            if self.starts_with(b"<!") {
                return Err(XML_ENTITY_ERROR.to_string());
            }
            return Ok(());
        }
    }

    /// A DOCTYPE with no internal subset is skipped; `[ … ]` defines entities
    /// and is refused rather than parsed.
    fn skip_doctype(&mut self) -> Result<(), String> {
        let rest = self.rest();
        for (offset, byte) in rest.iter().enumerate() {
            match byte {
                b'[' => return Err(XML_ENTITY_ERROR.to_string()),
                b'>' => {
                    self.at += offset + 1;
                    return Ok(());
                }
                _ => {}
            }
        }
        Err("iTerm2 plist: unterminated DOCTYPE.".to_string())
    }

    /// Reads a start tag: the element name, whether it self-closes, and
    /// whether it was a closing tag. Attributes are ignored.
    fn read_tag(&mut self) -> Result<(String, bool, bool), String> {
        if !self.starts_with(b"<") {
            return Err("iTerm2 plist: expected an element.".to_string());
        }
        self.at += 1;
        if self.starts_with(b"!") || self.starts_with(b"?") {
            return Err(XML_ENTITY_ERROR.to_string());
        }
        let closing = self.starts_with(b"/");
        if closing {
            self.at += 1;
        }
        let name = self.read_name()?;
        let mut self_closing = false;
        loop {
            match self.rest().first() {
                None => return Err("iTerm2 plist: unterminated tag.".to_string()),
                Some(b'>') => {
                    self.at += 1;
                    break;
                }
                Some(b'/') => {
                    self.at += 1;
                    if self.starts_with(b">") {
                        self.at += 1;
                        self_closing = true;
                        break;
                    }
                    return Err("iTerm2 plist: malformed tag.".to_string());
                }
                Some(_) => {
                    // An attribute: skip to the end of the tag, refusing a
                    // quote imbalance is unnecessary because only `>` ends it.
                    self.at += 1;
                }
            }
        }
        Ok((name, self_closing, closing))
    }

    fn read_name(&mut self) -> Result<String, String> {
        let start = self.at;
        while let Some(b) = self.rest().first() {
            if b.is_ascii_alphanumeric() || *b == b'_' {
                self.at += 1;
            } else {
                break;
            }
        }
        if self.at == start {
            return Err("iTerm2 plist: empty element name.".to_string());
        }
        std::str::from_utf8(&self.bytes[start..self.at])
            .map(str::to_string)
            .map_err(|_| "iTerm2 plist: invalid UTF-8.".to_string())
    }

    /// Text of an element up to `</name>`, with the five predefined entities
    /// decoded. A bare `&` or a nested `<` is refused.
    fn read_text(&mut self, name: &str) -> Result<String, String> {
        let mut out = String::new();
        loop {
            if self.starts_with(b"</") {
                let closing = format!("</{name}>");
                self.expect(&closing)?;
                return Ok(out);
            }
            if self.starts_with(b"<!") {
                return Err(XML_ENTITY_ERROR.to_string());
            }
            let Some(byte) = self.rest().first().copied() else {
                return Err(format!("iTerm2 plist: unterminated <{name}>."));
            };
            if byte == b'<' {
                return Err(format!("iTerm2 plist: <{name}> holds a nested element."));
            }
            if byte == b'&' {
                let rest = self.rest();
                let (decoded, width) = decode_entity(rest)?;
                out.push(decoded);
                self.at += width;
                continue;
            }
            let rest = self.rest();
            let width = std::str::from_utf8(rest)
                .ok()
                .and_then(|s| s.chars().next())
                .map(|c| c.len_utf8())
                .unwrap_or(1);
            let piece = std::str::from_utf8(&rest[..width])
                .map_err(|_| "iTerm2 plist: invalid UTF-8.".to_string())?;
            out.push_str(piece);
            self.at += width;
        }
    }
}

fn decode_entity(rest: &[u8]) -> Result<(char, usize), String> {
    const ENTITIES: [(&str, char); 5] = [
        ("&amp;", '&'),
        ("&lt;", '<'),
        ("&gt;", '>'),
        ("&quot;", '"'),
        ("&apos;", '\''),
    ];
    for (pattern, decoded) in ENTITIES {
        if rest.starts_with(pattern.as_bytes()) {
            return Ok((decoded, pattern.len()));
        }
    }
    Err(XML_ENTITY_ERROR.to_string())
}

fn parse_iterm_plist(text: &str, stem: &str) -> Result<Scheme, String> {
    let mut reader = XmlReader::new(text);
    reader.skip_misc()?;
    let (root, self_closing, closing) = reader.read_tag()?;
    if root != "plist" || self_closing || closing {
        return Err("iTerm2 plist: the file must open with <plist>.".to_string());
    }
    reader.skip_misc()?;
    let (tag, _, closing) = reader.read_tag()?;
    if tag != "dict" || closing {
        return Err("iTerm2 plist: <plist> must hold one <dict>.".to_string());
    }
    let entries = parse_plist_dict(&mut reader, 1)?;
    reader.skip_misc()?;
    reader.expect("</plist>")?;
    reader.skip_misc()?;
    if !reader.rest().is_empty() {
        return Err("iTerm2 plist: trailing content after </plist>.".to_string());
    }

    let mut palette = SYSTEM_COLORS;
    for (slot, entry) in palette.iter_mut().enumerate() {
        let key = format!("Ansi {slot} Color");
        if let Some(value) = entries.get(&key) {
            *entry = plist_colour(value, &key)?;
        }
    }
    let background = plist_colour(
        entries
            .get("Background Color")
            .ok_or_else(|| "An iTerm2 scheme needs \"Background Color\".".to_string())?,
        "Background Color",
    )?;
    let foreground = plist_colour(
        entries
            .get("Foreground Color")
            .ok_or_else(|| "An iTerm2 scheme needs \"Foreground Color\".".to_string())?,
        "Foreground Color",
    )?;
    let cursor = match entries.get("Cursor Color") {
        Some(value) => plist_colour(value, "Cursor Color")?,
        None => foreground,
    };
    let selection = match entries.get("Selection Color") {
        Some(value) => plist_colour(value, "Selection Color")?,
        None => palette[8],
    };
    Ok(Scheme {
        name: sanitize_name(stem),
        palette,
        foreground,
        background,
        cursor,
        selection,
    })
}

fn parse_plist_dict(
    reader: &mut XmlReader<'_>,
    depth: usize,
) -> Result<BTreeMap<String, Plist>, String> {
    if depth > XML_DEPTH_CAP {
        return Err("iTerm2 plist: nested too deeply.".to_string());
    }
    let mut map = BTreeMap::new();
    loop {
        reader.skip_misc()?;
        if reader.starts_with(b"</") {
            reader.expect("</dict>")?;
            return Ok(map);
        }
        if reader.rest().is_empty() {
            return Err("iTerm2 plist: unterminated <dict>.".to_string());
        }
        let (tag, _, closing) = reader.read_tag()?;
        if tag != "key" || closing {
            return Err("iTerm2 plist: a <dict> holds <key> elements.".to_string());
        }
        let key = reader.read_text("key")?;
        reader.skip_misc()?;
        let value = parse_plist_value(reader, depth + 1)?;
        map.insert(key, value);
    }
}

fn parse_plist_value(reader: &mut XmlReader<'_>, depth: usize) -> Result<Plist, String> {
    if depth > XML_DEPTH_CAP {
        return Err("iTerm2 plist: nested too deeply.".to_string());
    }
    reader.skip_misc()?;
    let (tag, self_closing, closing) = reader.read_tag()?;
    if closing {
        return Err("iTerm2 plist: unexpected closing tag.".to_string());
    }
    match tag.as_str() {
        "dict" => {
            if self_closing {
                Ok(Plist::Dict(BTreeMap::new()))
            } else {
                parse_plist_dict(reader, depth).map(Plist::Dict)
            }
        }
        "real" | "integer" | "string" => {
            let text = if self_closing {
                String::new()
            } else {
                reader.read_text(&tag)?
            };
            match tag.as_str() {
                "real" => text
                    .trim()
                    .parse::<f64>()
                    .map(Plist::Real)
                    .map_err(|_| "iTerm2 plist: a <real> is not a number.".to_string()),
                "integer" => text
                    .trim()
                    .parse::<i64>()
                    .map(Plist::Int)
                    .map_err(|_| "iTerm2 plist: an <integer> is not a number.".to_string()),
                _ => Ok(Plist::Str),
            }
        }
        "true" | "false" => {
            if !self_closing {
                reader.read_text(&tag)?;
            }
            Ok(Plist::Bool(tag == "true"))
        }
        other => Err(format!("iTerm2 plist: <{other}> is not supported.")),
    }
}

fn plist_colour(value: &Plist, what: &str) -> Result<[u8; 3], String> {
    let Plist::Dict(components) = value else {
        return Err(format!("\"{what}\" is not a colour dictionary."));
    };
    let component = |name: &str| -> Result<f64, String> {
        match components.get(name) {
            Some(Plist::Real(v)) => Ok(*v),
            Some(Plist::Int(v)) => Ok(*v as f64),
            Some(Plist::Bool(v)) => Ok(if *v { 1.0 } else { 0.0 }),
            _ => Err(format!("\"{what}\" is missing \"{name}\".")),
        }
    };
    let channel = |name: &str| -> Result<u8, String> {
        let v = component(name)?;
        Ok((v.clamp(0.0, 1.0) * 255.0).round() as u8)
    };
    Ok([
        channel("Red Component")?,
        channel("Green Component")?,
        channel("Blue Component")?,
    ])
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    fn native_body() -> String {
        let palette: Vec<String> = (0..16)
            .map(|i| format!("\"#{i:02x}{i:02x}{i:02x}\""))
            .collect();
        format!(
            "{{\"name\":\"probe\",\"palette\":[{}],\"foreground\":\"#abcdef\",\
             \"background\":\"#123456\",\"cursor\":\"#e0e0e0\",\"selection\":\"#445566\"}}",
            palette.join(",")
        )
    }

    #[test]
    fn native_json_reads_all_six_keys() {
        let scheme = parse_scheme(&native_body(), "probe.json").expect("native parses");
        assert_eq!(scheme.name, "probe");
        assert_eq!(scheme.palette[3], [3, 3, 3]);
        assert_eq!(scheme.foreground, [0xab, 0xcd, 0xef]);
        assert_eq!(scheme.background, [0x12, 0x34, 0x56]);
        assert_eq!(scheme.cursor, [0xe0, 0xe0, 0xe0]);
        assert_eq!(scheme.selection, [0x44, 0x55, 0x66]);
    }

    #[test]
    fn native_json_rejects_an_unknown_key() {
        let body = native_body().replace("\"name\"", "\"colour\":\"#000000\",\"name\"");
        let error = parse_scheme(&body, "x.json").expect_err("closed keys");
        assert!(error.contains("Unknown key \"colour\""), "{error}");
    }

    #[test]
    fn native_json_requires_sixteen_palette_entries() {
        let body =
            "{\"palette\":[\"#000000\"],\"foreground\":\"#ffffff\",\"background\":\"#000000\"}";
        let error = parse_scheme(body, "x.json").expect_err("short palette");
        assert!(error.contains("exactly 16"), "{error}");
    }

    #[test]
    fn native_json_rejects_a_malformed_hex() {
        let body = native_body().replace("\"#030303\"", "\"#zzzzzz\"");
        let error = parse_scheme(&body, "x.json").expect_err("bad hex");
        assert!(error.contains("palette[3]"), "{error}");
    }

    fn iterm_plist() -> String {
        let mut entries = String::new();
        for slot in 0..16 {
            let v = if slot == 1 { 1.0 } else { 0.5 };
            entries.push_str(&format!(
                "<key>Ansi {slot} Color</key><dict>\
                 <key>Red Component</key><real>{v}</real>\
                 <key>Green Component</key><real>{v}</real>\
                 <key>Blue Component</key><real>{v}</real>\
                 </dict>"
            ));
        }
        format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
             <!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n\
             <plist version=\"1.0\"><dict>{entries}\
             <key>Background Color</key><dict>\
             <key>Red Component</key><real>0.1</real>\
             <key>Green Component</key><real>0.2</real>\
             <key>Blue Component</key><real>0.3</real></dict>\
             <key>Foreground Color</key><dict>\
             <key>Red Component</key><real>1</real>\
             <key>Green Component</key><real>1</real>\
             <key>Blue Component</key><real>1</real></dict>\
             <key>Cursor Color</key><dict>\
             <key>Red Component</key><real>0</real>\
             <key>Green Component</key><real>0.25</real>\
             <key>Blue Component</key><real>0.5</real></dict>\
             </dict></plist>"
        )
    }

    #[test]
    fn iterm2_reads_ansi_and_named_colours() {
        let scheme = parse_scheme(&iterm_plist(), "Probe.itermcolors").expect("parses");
        assert_eq!(scheme.palette[1], [255, 255, 255]);
        assert_eq!(scheme.palette[0], [128, 128, 128]);
        assert_eq!(scheme.background, [26, 51, 77]);
        assert_eq!(scheme.foreground, [255, 255, 255]);
        assert_eq!(scheme.cursor, [0, 64, 128]);
        assert_eq!(scheme.selection, scheme.palette[8], "selection falls back");
        assert_eq!(scheme.name, "Probe");
    }

    #[test]
    fn iterm2_refuses_an_entity_definition_and_an_unknown_entity() {
        // A real file's prolog (declaration + plain DOCTYPE) parses; an
        // internal subset, where entities are defined, is refused.
        let subset = iterm_plist().replace(
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \
             \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">",
            "<!DOCTYPE plist [<!ENTITY x \"y\">]>",
        );
        let error = parse_scheme(&subset, "x.itermcolors").expect_err("subset");
        assert!(error.contains("entity"), "{error}");

        let unknown = iterm_plist().replace("<key>Ansi 0 Color</key>", "<key>Ansi 0&bogus;X</key>");
        let error = parse_scheme(&unknown, "x.itermcolors").expect_err("unknown entity");
        assert!(error.contains("entity"), "{error}");
    }

    #[test]
    fn alacritty_toml_reads_normal_bright_primary_cursor_selection() {
        let text = r##"
[colors.primary]
background = "0x112233"
foreground = "#ddeeff"

[colors.normal]
black = "0x000000"
red = "0x010101"
green = "0x020202"
yellow = "0x030303"
blue = "0x040404"
magenta = "0x050505"
cyan = "0x060606"
white = "0x070707"

[colors.bright]
black = "0x080808"
red = "0x090909"
green = "0x0a0a0a"
yellow = "0x0b0b0b"
blue = "0x0c0c0c"
magenta = "0x0d0d0d"
cyan = "0x0e0e0e"
white = "0x0f0f0f"

[colors.cursor]
cursor = "0xabcdef"

[colors.selection]
background = "0x445566"
"##;
        let scheme = parse_scheme(text, "alacritty.toml").expect("parses");
        assert_eq!(scheme.palette[0], [0, 0, 0]);
        assert_eq!(scheme.palette[9], [9, 9, 9]);
        assert_eq!(scheme.palette[15], [15, 15, 15]);
        assert_eq!(scheme.background, [0x11, 0x22, 0x33]);
        assert_eq!(scheme.foreground, [0xdd, 0xee, 0xff]);
        assert_eq!(scheme.cursor, [0xab, 0xcd, 0xef]);
        assert_eq!(scheme.selection, [0x44, 0x55, 0x66]);
    }

    #[test]
    fn alacritty_yaml_reads_the_same_scheme() {
        let text = r##"
colors:
  primary:
    background: '0x112233'
    foreground: "#ddeeff"
  normal:
    black: '0x000000'
    red: '0x010101'
    green: '0x020202'
    yellow: '0x030303'
    blue: '0x040404'
    magenta: '0x050505'
    cyan: '0x060606'
    white: '0x070707'
  bright:
    black: '0x080808'
    red: '0x090909'
    green: '0x0a0a0a'
    yellow: '0x0b0b0b'
    blue: '0x0c0c0c'
    magenta: '0x0d0d0d'
    cyan: '0x0e0e0e'
    white: '0x0f0f0f'
"##;
        let scheme = parse_scheme(text, "alacritty.yml").expect("parses");
        assert_eq!(scheme.palette[0], [0, 0, 0]);
        assert_eq!(scheme.palette[15], [15, 15, 15]);
        assert_eq!(scheme.background, [0x11, 0x22, 0x33]);
        assert_eq!(scheme.foreground, [0xdd, 0xee, 0xff]);
        assert_eq!(scheme.cursor, scheme.foreground, "cursor defaults to fg");
        assert_eq!(scheme.selection, scheme.palette[8]);
    }

    #[test]
    fn base16_uses_the_shell_mapping() {
        let mut text = String::from("scheme: \"Probe\"\n");
        for slot in 0..16 {
            text.push_str(&format!(
                "base{slot:02X}: \"{slot:02x}{slot:02x}{slot:02x}\"\n"
            ));
        }
        let scheme = parse_scheme(&text, "probe.yaml").expect("parses");
        // 0=base00 1=base08 2=base0B 3=base0A 4=base0D 5=base0E 6=base0C
        // 7=base05 8=base03 9=base09 10=base01 11=base02 12=base04 13=base06
        // 14=base0F 15=base07
        let expected = [0, 8, 11, 10, 13, 14, 12, 5, 3, 9, 1, 2, 4, 6, 15, 7];
        for (slot, base) in expected.iter().enumerate() {
            assert_eq!(scheme.palette[slot], [*base as u8; 3], "slot {slot}");
        }
        assert_eq!(scheme.background, [0, 0, 0]);
        assert_eq!(scheme.foreground, [5, 5, 5]);
        assert_eq!(scheme.cursor, [5, 5, 5]);
        assert_eq!(scheme.selection, [2, 2, 2]);
        assert_eq!(scheme.name, "Probe");
    }

    #[test]
    fn legacy_csv_fills_missing_slots_from_the_system_palette() {
        let scheme = parse_scheme("#112233,#445566", "old.txt").expect("parses");
        assert_eq!(scheme.palette[0], [0x11, 0x22, 0x33]);
        assert_eq!(scheme.palette[1], [0x44, 0x55, 0x66]);
        assert_eq!(&scheme.palette[2..], &SYSTEM_COLORS[2..]);
        assert_eq!(scheme.background, [0x11, 0x22, 0x33]);
        assert_eq!(scheme.foreground, SYSTEM_COLORS[7]);
        assert_eq!(scheme.selection, SYSTEM_COLORS[8]);
    }

    #[test]
    fn a_scheme_over_the_byte_cap_is_refused() {
        let text = "#000000,".repeat(MAX_SCHEME_BYTES);
        let error = parse_scheme(&text, "big.txt").expect_err("cap");
        assert!(error.contains("16 KiB"), "{error}");
    }

    #[test]
    fn the_name_is_sanitised_and_capped() {
        assert_eq!(sanitize_name("  a \n b\tc  "), "a b c");
        assert_eq!(sanitize_name(""), "Scheme");
        assert_eq!(sanitize_name("\u{7}"), "Scheme");
        let long = "x".repeat(200);
        assert_eq!(sanitize_name(&long).chars().count(), MAX_NAME_CHARS);
    }

    #[test]
    fn the_native_writer_round_trips_through_the_reader() {
        let original = parse_scheme(&native_body(), "probe.json").expect("parses");
        let written = to_native_json(&original);
        let reread = parse_scheme(&written, "probe.json").expect("round trip");
        assert_eq!(original, reread);
        assert!(written.ends_with("}\n"), "the file ends with a newline");
    }

    #[test]
    fn an_unrecognised_file_is_refused() {
        let error = parse_scheme("hello, world", "notes.txt").expect_err("not a scheme");
        assert_eq!(error, NOT_A_SCHEME);
    }
}
