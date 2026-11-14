//! The `--setting KEY=VALUE` vocabulary.
//!
//! One parser for the three doors that carry a pane's settings: `pane-set`,
//! `new-pane --setting`, and the MCP argument translation (`wire.rs`, which
//! accepts the same pair list). The wire shape they all produce is one JSON
//! object, which is what the GUI's closed table reads.

use serde_json::{Map, Value};

/// Parse `KEY=VALUE` pairs into the wire's settings object.
///
/// A value is JSON when it parses as one (`true`, `-6`, `["a", "b"]`) and a
/// string otherwise, which is what lets a path stay a bare path:
/// `file_path=/x/y` is the string `/x/y`, `muted=true` is a boolean. A pair
/// whose value parses to JSON `null` keeps the word as a string: a setting is
/// cleared with an empty value (`file_path=`), and the table has no null.
///
/// The key is trimmed and the value is not (a value may legitimately end in a
/// space); a repeated key is refused rather than letting the last one win,
/// because the caller meant one of them.
pub fn object_from(pairs: &[String]) -> Result<Value, String> {
    let mut out = Map::new();
    for pair in pairs {
        let (key, raw) = pair
            .split_once('=')
            .ok_or_else(|| format!("setting '{pair}' must be KEY=VALUE"))?;
        let key = key.trim();
        if key.is_empty() {
            return Err(format!("setting '{pair}' has no key"));
        }
        let value = match serde_json::from_str::<Value>(raw) {
            Ok(Value::Null) | Err(_) => Value::String(raw.to_string()),
            Ok(parsed) => parsed,
        };
        if out.insert(key.to_string(), value).is_some() {
            return Err(format!("setting '{key}' is given twice"));
        }
    }
    Ok(Value::Object(out))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn pairs(items: &[&str]) -> Vec<String> {
        items.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn a_bare_value_is_a_string_and_a_json_value_keeps_its_type() {
        let parsed = object_from(&pairs(&["file_path=/x/y", "muted=true", "volume_db=-6"]))
            .expect("a valid pair list parses");
        assert_eq!(
            parsed,
            json!({"file_path": "/x/y", "muted": true, "volume_db": -6})
        );
    }

    #[test]
    fn an_empty_value_clears_and_a_json_null_stays_a_word() {
        assert_eq!(
            object_from(&pairs(&["file_path="])).unwrap(),
            json!({"file_path": ""})
        );
        assert_eq!(
            object_from(&pairs(&["pane_name=null"])).unwrap(),
            json!({"pane_name": "null"}),
            "a setting is cleared with an empty value; the table has no null"
        );
        assert_eq!(
            object_from(&pairs(&["pane_name=\"7\""])).unwrap(),
            json!({"pane_name": "7"}),
            "a quoted number is the string the text rule takes"
        );
    }

    #[test]
    fn a_malformed_or_repeated_pair_is_named() {
        let why = object_from(&pairs(&["file_path"])).unwrap_err();
        assert!(why.contains("must be KEY=VALUE"), "{why}");
        let why = object_from(&pairs(&["=x"])).unwrap_err();
        assert!(why.contains("has no key"), "{why}");
        let why = object_from(&pairs(&["file_path=/a", "file_path=/b"])).unwrap_err();
        assert!(why.contains("file_path"), "{why}");
        assert!(why.contains("twice"), "{why}");
    }
}
