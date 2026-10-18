//! `gpty vault search|read|weight`: the knowledge base's agent access surface.
//!
//! Search and read are thin clients of the control socket's native
//! `vaultSearch`/`vaultRead` handlers (`crates/gpty-gdext/src/vault_ipc.rs`),
//! which own the walk, the index and the note editor's containment rules.
//! Nothing here decides what a note is.
//!
//! `weight` is the one *write* in the group, and it writes only the user's
//! declared-link store (`user://link_weights.json`, answered by the GUI's
//! `vaultWeight` handler): a display-only number for one directed link, or
//! its removal. It never touches a note or the index.

use std::time::Duration;

use crate::VaultAction;
use gpty_ipc::client::IpcClient;

/// A search re-indexes the vault before it queries, and one pass may read up
/// to `MAX_NOTES` (2000) notes whose mtime/size changed — bounded work, but
/// not a millisecond answer on a cold index. `--timeout` is the connection
/// budget every command shares (5 s by default), so the read budget for this
/// one call is derived the way `pane-wait` derives its own.
///
/// It stays under the server's dispatch budget for this method — the default
/// 30 s (`vaultSearch` is registered with `register`, not a longer
/// `register_with_timeout` budget): a longer client budget would wait past
/// the server's own `handler timed out` answer. A cold index that really
/// needs longer finishes on the blocking pool regardless, so the next query
/// is warm.
const VAULT_SEARCH_TIMEOUT: Duration = Duration::from_secs(25);

pub async fn run(client: &IpcClient, action: &VaultAction, json: bool) -> anyhow::Result<()> {
    match action {
        VaultAction::Search {
            vault_path,
            pattern,
            limit,
        } => {
            let params = serde_json::json!({
                "vault_path": vault_path,
                "pattern": pattern,
                "limit": limit,
            });
            let search_client = client.with_timeout(VAULT_SEARCH_TIMEOUT);
            super::call_and_format(&search_client, "vaultSearch", params, json).await
        }
        VaultAction::Read { vault_path, path } => {
            let params = serde_json::json!({"vault_path": vault_path, "path": path});
            super::call_and_format(client, "vaultRead", params, json).await
        }
        VaultAction::Weight {
            vault_path,
            src,
            target,
            weight,
            clear,
        } => {
            // The write surface is exactly one number: set it, or clear it.
            // Naming neither is a usage error rather than a silent clear, so
            // a typo cannot delete a declaration.
            if !clear && weight.is_none() {
                anyhow::bail!(
                    "give --weight <1-100> to declare a weight, or --clear to remove one"
                );
            }
            let params = serde_json::json!({
                "vault_path": vault_path,
                "src": src,
                "target": target,
                "weight": if *clear { serde_json::Value::Null } else { serde_json::json!(weight.unwrap_or(0)) },
            });
            super::call_and_format(client, "vaultWeight", params, json).await
        }
    }
}
