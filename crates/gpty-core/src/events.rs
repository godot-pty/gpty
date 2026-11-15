//! The adapter-neutral event vocabulary the event socket speaks.
//!
//! A plugin's `[[events]].type` names one of these (plus gpty's own
//! `pane.spawned` / `pane.killed` / `concept.matched`), and the socket
//! translates each adapter's wire names onto them at its trust boundary
//! (`crates/gpty-gdext/src/omp_events.rs`). The list lives here because two
//! crates validate against it — the CLI's plugin-manifest validator and the
//! extension's translator — and a second literal in either would drift: a
//! manifest that subscribed to an advertised name was refused as unknown
//! while the socket emitted it (the v0.8.4 row **A plugin cannot declare the
//! four newest event types**).
//!
//! Wire names belong to an adapter and stay with its translator; only the
//! generic contract is shared.

/// Every generic event name the socket can emit, in the socket's order.
///
/// `tool.call` keeps its historical spelling although the wire event is
/// `tool.started`: the name is public contract, so a rename is a break.
pub const GENERIC_EVENT_NAMES: &[&str] = &[
    "session.bound",
    "session.shutdown",
    "agent.started",
    "agent.settled",
    "turn.started",
    "turn.finished",
    "tool.call",
    "tool.finished",
    "thinking.delta",
    "state.declared",
];

#[cfg(test)]
mod tests {
    use super::GENERIC_EVENT_NAMES;

    /// One name, one meaning: a duplicate would let two wire events arrive
    /// under one generic name and make a subscriber's filter ambiguous.
    #[test]
    fn the_vocabulary_names_each_event_once() {
        let mut seen = std::collections::BTreeSet::new();
        for name in GENERIC_EVENT_NAMES {
            assert!(seen.insert(*name), "`{name}` is listed twice");
        }
        assert_eq!(seen.len(), GENERIC_EVENT_NAMES.len());
    }
}
