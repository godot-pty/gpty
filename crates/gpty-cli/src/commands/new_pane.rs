use gpty_ipc::client::IpcClient;

/// Valid pane type names.
const VALID_TYPES: &[&str] = &[
    "terminal",
    "code_viewer",
    "file_tree",
    "inspector",
    "reasoning",
    "observer",
];

pub async fn run(
    client: &IpcClient,
    pane_type: &str,
    command: Option<&str>,
    split: &str,
    title: Option<&str>,
    focus: bool,
    json: bool,
) -> anyhow::Result<()> {
    // Validate pane type with "did you mean?" suggestions.
    if !VALID_TYPES.contains(&pane_type) {
        let suggestion = closest_match(pane_type, VALID_TYPES);
        let hint = match suggestion {
            Some(s) => format!(" — did you mean \"{s}\"?"),
            None => String::new(),
        };
        anyhow::bail!(
            "invalid pane type: \"{pane_type}\"{hint}\nValid types: {}",
            VALID_TYPES.join(", ")
        );
    }

    let wire_type = if pane_type == "observer" {
        eprintln!("warning: pane type \"observer\" is deprecated; using \"inspector\"");
        "inspector"
    } else {
        pane_type
    };
    let mut params = serde_json::json!({
        "type": wire_type,
        "split": split,
        "focus": focus,
    });
    if let Some(cmd) = command {
        params["command"] = serde_json::Value::String(cmd.to_string());
    }
    if let Some(t) = title {
        params["title"] = serde_json::Value::String(t.to_string());
    }
    super::call_and_format(client, "newPane", params, json).await
}

/// Find the closest valid match using Levenshtein distance.
fn closest_match<'a>(input: &str, valid: &[&'a str]) -> Option<&'a str> {
    let input = input.to_lowercase();
    valid
        .iter()
        .filter_map(|&v| {
            let dist = levenshtein_distance(&input, v);
            let threshold = (v.len().max(input.len()) / 2).min(3);
            if dist <= threshold {
                Some((dist, v))
            } else {
                None
            }
        })
        .min_by_key(|(d, _)| *d)
        .map(|(_, v)| v)
}

fn levenshtein_distance(a: &str, b: &str) -> usize {
    let a_chars: Vec<char> = a.chars().collect();
    let b_chars: Vec<char> = b.chars().collect();
    let n = a_chars.len();
    let m = b_chars.len();
    if n == 0 {
        return m;
    }
    if m == 0 {
        return n;
    }
    let mut prev: Vec<usize> = (0..=m).collect();
    let mut curr = vec![0usize; m + 1];
    for i in 1..=n {
        curr[0] = i;
        for j in 1..=m {
            let cost = if a_chars[i - 1] == b_chars[j - 1] {
                0
            } else {
                1
            };
            curr[j] = (prev[j] + 1).min(curr[j - 1] + 1).min(prev[j - 1] + cost);
        }
        std::mem::swap(&mut prev, &mut curr);
    }
    prev[m]
}
