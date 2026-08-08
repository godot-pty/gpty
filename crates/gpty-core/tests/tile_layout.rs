//! Integration tests for the tile layout algorithms used by workspace.gd.
//! These mirror the GDScript logic: split, kill, and expand operations.

const GRID: i32 = 12;
const MIN_TILE: i32 = 2;

#[derive(Debug, Clone, PartialEq)]
struct Tile {
    col: i32,
    row: i32,
    cspan: i32,
    rspan: i32,
}

/// Split the largest tile. Returns Some(new_tile) or None if too small.
fn split_largest(tiles: &mut Vec<Tile>) -> Option<Tile> {
    if tiles.is_empty() {
        return None;
    }

    let bi = tiles
        .iter()
        .enumerate()
        .max_by_key(|(_, t)| t.cspan * t.rspan)
        .map(|(i, _)| i)
        .unwrap();

    let s = &mut tiles[bi];
    let oc = s.col;
    let or_ = s.row;
    let os = s.cspan;
    let ot = s.rspan;

    if os >= ot {
        let half = (os / 2).max(1);
        if half < MIN_TILE || (os - half) < MIN_TILE {
            return None;
        }
        s.cspan = half;
        let new_tile = Tile { col: oc + half, row: or_, cspan: os - half, rspan: ot };
        tiles.push(new_tile.clone());
        Some(new_tile)
    } else {
        let half = (ot / 2).max(1);
        if half < MIN_TILE || (ot - half) < MIN_TILE {
            return None;
        }
        s.rspan = half;
        let new_tile = Tile { col: oc, row: or_ + half, cspan: os, rspan: ot - half };
        tiles.push(new_tile.clone());
        Some(new_tile)
    }
}

/// Remove a tile. Try exact-match expansion first, then partial.
fn kill_tile(tiles: &mut Vec<Tile>, idx: usize) {
    let rm = tiles.remove(idx);
    if !expand_exact(tiles, &rm) {
        expand_partial(tiles, &rm);
    }
}

/// Exact-match: adjacent tile with identical row or column span.
fn expand_exact(tiles: &mut Vec<Tile>, rm: &Tile) -> bool {
    for t in tiles.iter_mut() {
        if t.row == rm.row && t.rspan == rm.rspan {
            if t.col + t.cspan == rm.col {
                t.cspan += rm.cspan;
                return true;
            }
            if rm.col + rm.cspan == t.col {
                t.col = rm.col;
                t.cspan += rm.cspan;
                return true;
            }
        }
        if t.col == rm.col && t.cspan == rm.cspan {
            if t.row + t.rspan == rm.row {
                t.rspan += rm.rspan;
                return true;
            }
            if rm.row + rm.rspan == t.row {
                t.row = rm.row;
                t.rspan += rm.rspan;
                return true;
            }
        }
    }
    false
}

/// Partial expand: find all tiles sharing an edge with rm.
fn expand_partial(tiles: &mut Vec<Tile>, rm: &Tile) {
    let mut left = vec![];
    let mut right = vec![];
    let mut up = vec![];
    let mut down = vec![];

    for (i, t) in tiles.iter().enumerate() {
        if t.col + t.cspan == rm.col {
            left.push(i);
        }
        if rm.col + rm.cspan == t.col {
            right.push(i);
        }
        if t.row + t.rspan == rm.row {
            up.push(i);
        }
        if rm.row + rm.rspan == t.row {
            down.push(i);
        }
    }

    if !left.is_empty() || !right.is_empty() {
        let new_right = rm.col + rm.cspan;
        for &i in &left {
            tiles[i].cspan = new_right - tiles[i].col;
        }
        for &i in &right {
            let old_right = tiles[i].col + tiles[i].cspan;
            tiles[i].col = rm.col;
            tiles[i].cspan = old_right - rm.col;
        }
        return;
    }
    if !up.is_empty() || !down.is_empty() {
        let new_bottom = rm.row + rm.rspan;
        for &i in &up {
            tiles[i].rspan = new_bottom - tiles[i].row;
        }
        for &i in &down {
            let old_bottom = tiles[i].row + tiles[i].rspan;
            tiles[i].row = rm.row;
            tiles[i].rspan = old_bottom - rm.row;
        }
        return;
    }
    // Fallback
    if let Some(t) = tiles.first_mut() {
        t.col = 0;
        t.row = 0;
        t.cspan = GRID;
        t.rspan = GRID;
    }
}

/// Check that no tiles overlap.
fn no_overlap(tiles: &[Tile]) -> bool {
    for i in 0..tiles.len() {
        for j in (i + 1)..tiles.len() {
            let a = &tiles[i];
            let b = &tiles[j];
            let col_overlap = a.col < b.col + b.cspan && b.col < a.col + a.cspan;
            let row_overlap = a.row < b.row + b.rspan && b.row < a.row + a.rspan;
            if col_overlap && row_overlap {
                return false;
            }
        }
    }
    true
}

/// Check that the entire grid is covered (no gaps).
fn full_coverage(tiles: &[Tile]) -> bool {
    // Simple check: sum of areas equals grid area
    let total_area: i32 = tiles.iter().map(|t| t.cspan * t.rspan).sum();
    total_area == GRID * GRID
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    fn make_grid() -> Vec<Tile> {
        vec![Tile { col: 0, row: 0, cspan: GRID, rspan: GRID }]
    }

    #[test]
    fn one_to_two_tiles() {
        let mut tiles = make_grid();
        split_largest(&mut tiles);
        assert_eq!(tiles.len(), 2);
        assert!(no_overlap(&tiles));
        assert!(full_coverage(&tiles));
    }

    #[test]
    fn two_to_three_tiles() {
        let mut tiles = make_grid();
        split_largest(&mut tiles); // 1→2
        split_largest(&mut tiles); // 2→3
        assert_eq!(tiles.len(), 3);
        assert!(no_overlap(&tiles));
        assert!(full_coverage(&tiles));
    }

    #[test]
    fn up_to_five_tiles() {
        let mut tiles = make_grid();
        for _ in 0..4 {
            assert!(split_largest(&mut tiles).is_some());
        }
        assert_eq!(tiles.len(), 5);
        assert!(no_overlap(&tiles));
        assert!(full_coverage(&tiles));
    }

    #[test]
    fn kill_from_three_restores_no_overlap() {
        let mut tiles = make_grid();
        split_largest(&mut tiles); // T1, T2
        split_largest(&mut tiles); // T1 split vertically → T1, T3, T2

        // Remove T2 (the right-half tile)
        let t2_idx = tiles.iter().position(|t| t.col == 6 && t.row == 0).unwrap();
        kill_tile(&mut tiles, t2_idx);

        assert_eq!(tiles.len(), 2);
        assert!(no_overlap(&tiles));
        assert!(full_coverage(&tiles));
    }

    #[test]
    fn kill_from_four_restores_no_overlap() {
        let mut tiles = make_grid();
        for _ in 0..3 {
            split_largest(&mut tiles);
        }
        // 4 tiles: T1(0,0,6,6), T3(0,6,6,6), T2(6,0,6,6), T4(6,6,6,6)

        // Remove T2
        let idx = tiles.iter().position(|t| t.col == 6 && t.row == 0 && t.cspan == 6 && t.rspan == 6).unwrap();
        kill_tile(&mut tiles, idx);

        assert_eq!(tiles.len(), 3);
        assert!(no_overlap(&tiles));
        assert!(full_coverage(&tiles));
    }

    #[test]
    fn min_tile_limit_reached() {
        // Split until we can't anymore
        let mut tiles = make_grid();
        let mut count = 0;
        while split_largest(&mut tiles).is_some() {
            count += 1;
            assert!(no_overlap(&tiles));
        }
        // With GRID=12 and MIN_TILE=2, max tiles = (12/2)*(12/2) = 36
        assert_eq!(tiles.len(), 16); // 12/3=4, 4×4=16 (3-cell tiles are min)
        assert!(count > 0);
    }

    #[test]
    fn random_kill_sequence() {
        let mut tiles = make_grid();
        // Build up to 8 tiles
        for _ in 0..7 {
            split_largest(&mut tiles);
        }
        assert_eq!(tiles.len(), 8);

        // Kill tiles in reverse order
        while tiles.len() > 1 {
            let last = tiles.len() - 1; kill_tile(&mut tiles, last);
            assert!(no_overlap(&tiles), "overlap after kill, {} tiles left", tiles.len());
            assert!(full_coverage(&tiles), "gap after kill, {} tiles left", tiles.len());
        }
    }

    #[test]
    fn exact_expand_horizontal() {
        let mut tiles = vec![
            Tile { col: 0, row: 0, cspan: 6, rspan: GRID },
            Tile { col: 6, row: 0, cspan: 6, rspan: GRID },
        ];
        kill_tile(&mut tiles, 1); // remove right tile
        assert_eq!(tiles.len(), 1);
        assert_eq!(tiles[0].cspan, GRID);
        assert!(full_coverage(&tiles));
    }

    #[test]
    fn exact_expand_vertical() {
        let mut tiles = vec![
            Tile { col: 0, row: 0, cspan: GRID, rspan: 6 },
            Tile { col: 0, row: 6, cspan: GRID, rspan: 6 },
        ];
        kill_tile(&mut tiles, 1); // remove bottom tile
        assert_eq!(tiles.len(), 1);
        assert_eq!(tiles[0].rspan, GRID);
    }

    #[test]
    fn partial_expand_from_mixed_split() {
        // Scenario: 3 tiles after T1 split vertically, T2 on right
        let mut tiles = vec![
            Tile { col: 0, row: 0, cspan: 6, rspan: 6 },  // T1 top-left
            Tile { col: 0, row: 6, cspan: 6, rspan: 6 },  // T3 bottom-left
            Tile { col: 6, row: 0, cspan: 6, rspan: GRID }, // T2 full right
        ];
        let rm_idx = 2; // remove T2
        kill_tile(&mut tiles, rm_idx);

        assert_eq!(tiles.len(), 2);
        assert!(no_overlap(&tiles));
        assert!(full_coverage(&tiles));
        // Both T1 and T3 should be full width
        for t in &tiles {
            assert_eq!(t.cspan, GRID);
        }
    }

    #[test]
    fn partial_expand_right_covers_removed_tile() {
        // T1(0,0,4,12) left, T2(4,0,8,6) top-right, T3(4,6,8,6) bottom-right.
        // Remove T1 — T2 and T3 should expand left to fill the gap.
        let mut tiles = vec![
            Tile { col: 0, row: 0, cspan: 4, rspan: GRID },
            Tile { col: 4, row: 0, cspan: 8, rspan: 6 },
            Tile { col: 4, row: 6, cspan: 8, rspan: 6 },
        ];
        kill_tile(&mut tiles, 0); // remove left tile
        assert_eq!(tiles.len(), 2);
        assert!(no_overlap(&tiles));
        assert!(full_coverage(&tiles));
        // Both should now start at col 0 and span the full width
        for t in &tiles {
            assert_eq!(t.col, 0);
            assert_eq!(t.cspan, GRID);
        }
    }

    #[test]
    fn partial_expand_down_covers_removed_tile() {
        // T1(0,0,12,4) top, T2(0,4,6,8) bottom-left, T3(6,4,6,8) bottom-right.
        // Remove T1 — T2 and T3 should expand up to fill the gap.
        let mut tiles = vec![
            Tile { col: 0, row: 0, cspan: GRID, rspan: 4 },
            Tile { col: 0, row: 4, cspan: 6, rspan: 8 },
            Tile { col: 6, row: 4, cspan: 6, rspan: 8 },
        ];
        kill_tile(&mut tiles, 0); // remove top tile
        assert_eq!(tiles.len(), 2);
        assert!(no_overlap(&tiles));
        assert!(full_coverage(&tiles));
        // Both should now start at row 0 and span the full height
        for t in &tiles {
            assert_eq!(t.row, 0);
            assert_eq!(t.rspan, GRID);
        }
    }
}
