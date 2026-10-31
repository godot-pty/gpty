//! Store-boundary facet of `GptyTerminal`: the owner-only rule for the files
//! gPTY keeps in its user directory.
//!
//! GDScript owns where a store lives (`BasePersistenceManager`) and sets the
//! mode when it writes one, but it cannot read a file's owner and
//! `FileAccess.set_unix_permissions` follows a symlink - so the *repair* half
//! (a store written by an older build, or the engine-created `user://` root)
//! lives in `gpty_core::owner_only` and is reached through the one static
//! below. Static, like the vault index's: the answer is about a path, not a
//! terminal, so an autoload can ask before any pane exists.

use crate::GptyTerminal;
use godot::prelude::*;
use gpty_core::owner_only;

#[godot_api(secondary)]
impl GptyTerminal {
    /// Tighten a store file, or the directory that holds them, to its owner.
    ///
    /// Returns an empty string when there was nothing to do - the path is
    /// missing, already owner-only, a symlink, not the kind the caller named,
    /// or another account's - or when the mode is now owner-only; otherwise
    /// the diagnostic to log, so the caller can throttle it. Best effort by
    /// design: a mode that cannot be set must never fail the load that asked
    /// for it.
    ///
    /// `directory` picks the rule: `false` expects a file and applies 0600,
    /// `true` expects a directory and applies 0700. On Windows there is no
    /// mode to repair (the profile directory's ACLs are inherited) and the
    /// answer is always empty.
    #[func]
    fn secure_store_path(path: GString, directory: bool) -> GString {
        let path = path.to_string();
        let restriction = if directory {
            owner_only::restrict_dir(std::path::Path::new(&path))
        } else {
            owner_only::restrict_file(std::path::Path::new(&path))
        };
        match restriction.problem(&path) {
            Some(problem) => GString::from(problem.as_str()),
            None => GString::new(),
        }
    }
}
