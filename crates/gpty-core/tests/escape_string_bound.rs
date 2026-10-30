//! A pane program must not be able to grow the GUI's memory by opening an
//! escape string and never closing it.
//!
//! The guard in front of the grid keeps the string payload finite; this test
//! proves it with a counting allocator rather than resident memory, so the
//! bound is deterministic and machine independent. Every string kind is fed,
//! so a dependency that starts buffering DCS, APC, PM or SOS fails here
//! instead of in production.

use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicUsize, Ordering};

use gpty_core::escstring::MAX_ESCAPE_STRING_BYTES;
use gpty_core::term::TermGrid;

/// Bytes currently allocated through the global allocator.
static LIVE: AtomicUsize = AtomicUsize::new(0);

struct Counting;

// Only `alloc` and `dealloc` are overridden: the default `realloc` is
// alloc + copy + dealloc, so a `Vec` growing through it is counted too.
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        LIVE.fetch_add(layout.size(), Ordering::Relaxed);
        unsafe { System.alloc(layout) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        LIVE.fetch_sub(layout.size(), Ordering::Relaxed);
        unsafe { System.dealloc(ptr, layout) }
    }
}

#[global_allocator]
static GLOBAL: Counting = Counting;

/// What the grid may hold while a string is open: the capped payload itself
/// plus the grid, the title copy and allocator slack. The unbounded case is
/// eight times this.
const ALLOWED_GROWTH: usize = 2 * 1024 * 1024;

/// Same size as `pty::READ_BUF_SIZE`, so the chunk boundaries match the ones
/// the engine actually produces.
const CHUNK: usize = 4096;

#[test]
fn an_unterminated_escape_string_cannot_grow_the_grid() {
    let payload = vec![b'x'; CHUNK];
    let chunks = 8 * 1024 * 1024 / CHUNK;

    // OSC is the kind that buffers in `vte`; the other four are read and
    // discarded, and the same assertion keeps them that way.
    for (kind, intro) in [
        ("OSC", b"\x1b]0;".as_slice()),
        ("DCS", b"\x1bP".as_slice()),
        ("APC", b"\x1b_".as_slice()),
        ("PM", b"\x1b^".as_slice()),
        ("SOS", b"\x1bX".as_slice()),
    ] {
        let mut grid = TermGrid::new_with_history(24, 80, 0);
        grid.feed(intro);
        let before = LIVE.load(Ordering::Relaxed);
        for _ in 0..chunks {
            grid.feed(&payload);
        }
        let growth = LIVE.load(Ordering::Relaxed).saturating_sub(before);
        assert!(
            growth <= ALLOWED_GROWTH,
            "{kind}: 8 MiB of unterminated payload grew the grid by {growth} bytes \
             (budget {MAX_ESCAPE_STRING_BYTES})"
        );
    }
}

/// The cap is what the grid keeps, and the stream recovers: the truncation
/// stops at the budget and later output renders normally.
#[test]
fn a_capped_string_is_truncated_and_parsing_resumes() {
    let mut grid = TermGrid::new_with_history(5, 40, 0);
    let mut flood = b"\x1b]0;".to_vec();
    flood.extend(std::iter::repeat_n(b'T', 4 * MAX_ESCAPE_STRING_BYTES));
    flood.extend_from_slice(b"\x07");
    grid.feed(&flood);

    assert!(
        grid.title().len() <= MAX_ESCAPE_STRING_BYTES + 1,
        "title kept {} bytes, cap is {MAX_ESCAPE_STRING_BYTES}",
        grid.title().len()
    );

    grid.feed(b"\r\n");
    grid.feed(b"\x1b[31mred\r\n");
    let rows = grid.renderable_rows();
    let red_row = rows
        .iter()
        .find(|row| row.first().is_some_and(|cell| cell.ch == 'r'))
        .expect("text after the capped string renders");
    assert_eq!(red_row[0].fg, [205, 0, 0], "and keeps its SGR colour");
}
