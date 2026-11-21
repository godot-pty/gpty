//! Color conversion — maps alacritty_terminal [`Color`] values to `[R, G, B]` triplets.
//!
//! Defines the standard 16 ANSI system colors as a shared array used by
//! both named-color and 256-color indexed lookups. Also handles the 6×6×6
//! RGB cube (indices 16–231) and the grayscale ramp (232–255).

use alacritty_terminal::vte::ansi::{Color, NamedColor};

use crate::term::CellInfo;

/// The 16 standard ANSI system colors, in indexed order (0–15).
pub const SYSTEM_COLORS: [[u8; 3]; 16] = [
    [0, 0, 0],       //  0 Black
    [205, 0, 0],     //  1 Red
    [0, 205, 0],     //  2 Green
    [205, 205, 0],   //  3 Yellow
    [0, 0, 238],     //  4 Blue
    [205, 0, 205],   //  5 Magenta
    [0, 205, 205],   //  6 Cyan
    [229, 229, 229], //  7 White
    [127, 127, 127], //  8 Bright Black
    [255, 0, 0],     //  9 Bright Red
    [0, 255, 0],     // 10 Bright Green
    [255, 255, 0],   // 11 Bright Yellow
    [92, 92, 255],   // 12 Bright Blue
    [255, 0, 255],   // 13 Bright Magenta
    [0, 255, 255],   // 14 Bright Cyan
    [255, 255, 255], // 15 Bright White
];

/// The terminal's resolved colours: the 16 ANSI entries plus the two a cell
/// uses when its SGR colour is the default (`NamedColor::Foreground` /
/// `Background`). A scheme's black is not its background (Nord's black is
/// `#3b4252`, its background `#2e3440`), so those two live beside the array
/// rather than being read out of slots 0 and 7.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Palette {
    pub ansi: [[u8; 3]; 16],
    pub foreground: [u8; 3],
    pub background: [u8; 3],
}

impl Palette {
    /// The engine's own colours: the ANSI set, white text on black.
    pub const fn system() -> Self {
        Self {
            ansi: SYSTEM_COLORS,
            foreground: SYSTEM_COLORS[7],
            background: SYSTEM_COLORS[0],
        }
    }

    /// A palette from a 16-colour CSV, with the legacy meaning of slots 0 and
    /// 7 as the background and foreground. A later explicit scheme overrides
    /// them through the fields.
    pub fn from_ansi(ansi: [[u8; 3]; 16]) -> Self {
        Self {
            ansi,
            foreground: ansi[7],
            background: ansi[0],
        }
    }

    /// The colour a cell paints, with the grid's default pair resolved.
    pub fn resolve(&self, color: &Color) -> [u8; 3] {
        match color {
            Color::Named(NamedColor::Foreground) => self.foreground,
            Color::Named(NamedColor::Background) => self.background,
            _ => color_to_rgb(color, &self.ansi),
        }
    }
}

impl Default for Palette {
    fn default() -> Self {
        Self::system()
    }
}

/// Build the 16-colour palette a scheme CSV describes.
///
/// A scheme may carry fewer than 16 entries, or a malformed one; those slots
/// keep [`SYSTEM_COLORS`] rather than whatever the previous scheme left in the
/// grid. That is why this answers a complete array instead of writing into the
/// caller's: a scheme is a set, not a patch.
pub fn palette_from_csv(csv: &str) -> [[u8; 3]; 16] {
    let mut palette = SYSTEM_COLORS;
    for (i, hex) in csv.split(',').enumerate().take(16) {
        let h = hex.trim();
        if h.len() == 7
            && h.starts_with('#')
            && let (Ok(r), Ok(g), Ok(b)) = (
                u8::from_str_radix(&h[1..3], 16),
                u8::from_str_radix(&h[3..5], 16),
                u8::from_str_radix(&h[5..7], 16),
            )
        {
            palette[i] = [r, g, b];
        }
    }
    palette
}

/// Convert an alacritty/vte `Color` to an `[R, G, B]` triplet.
///
/// Named colors use the standard xterm-256color palette. Indexed colors
/// (256-color mode) are approximated. True-color is passed through
/// directly.
pub fn color_to_rgb(color: &Color, palette: &[[u8; 3]; 16]) -> [u8; 3] {
    match color {
        Color::Named(named) => named_to_rgb(named, palette),
        Color::Spec(rgb) => [rgb.r, rgb.g, rgb.b],
        Color::Indexed(idx) => indexed_to_rgb(*idx, palette),
    }
}

/// Map standard 16 ANSI named colors to approximate RGB values.
fn named_to_rgb(named: &NamedColor, palette: &[[u8; 3]; 16]) -> [u8; 3] {
    match named {
        NamedColor::Background => palette[0],
        NamedColor::Foreground => palette[7],
        NamedColor::Black => palette[0],
        NamedColor::Red => palette[1],
        NamedColor::Green => palette[2],
        NamedColor::Yellow => palette[3],
        NamedColor::Blue => palette[4],
        NamedColor::Magenta => palette[5],
        NamedColor::Cyan => palette[6],
        NamedColor::White => palette[7],
        NamedColor::BrightBlack => palette[8],
        NamedColor::BrightRed => palette[9],
        NamedColor::BrightGreen => palette[10],
        NamedColor::BrightYellow => palette[11],
        NamedColor::BrightBlue => palette[12],
        NamedColor::BrightMagenta => palette[13],
        NamedColor::BrightCyan => palette[14],
        NamedColor::BrightWhite => palette[15],
        NamedColor::BrightForeground => palette[15], // same as BrightWhite
        NamedColor::DimBlack => palette[0],
        NamedColor::DimRed => palette[1],
        NamedColor::DimGreen => palette[2],
        NamedColor::DimYellow => palette[3],
        NamedColor::DimBlue => palette[4],
        NamedColor::DimMagenta => palette[5],
        NamedColor::DimCyan => palette[6],
        NamedColor::DimWhite => palette[7],
        // Cursor, ViMode, search match — fall back to default foreground
        _ => CellInfo::DEFAULT_FG,
    }
}

/// Approximate a 256-color palette index to an RGB triplet.
///
/// Colors 0–15 are system colors, 16–231 form a 6×6×6 RGB cube, and
/// 232–255 form a grayscale ramp. This follows the standard xterm
/// 256-color palette.
fn indexed_to_rgb(idx: u8, palette: &[[u8; 3]; 16]) -> [u8; 3] {
    match idx {
        0..=15 => palette[idx as usize],
        // 16–231: 6×6×6 color cube
        n if n < 232 => {
            let n = n - 16;
            let r = (n / 36) * 51;
            let g = ((n / 6) % 6) * 51;
            let b = (n % 6) * 51;
            [r, g, b]
        }
        // 232–255: grayscale ramp (8 to 238 in steps of 10)
        n => {
            let gray = (n as u16 - 232) * 10 + 8;
            [gray as u8, gray as u8, gray as u8]
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn indexed_boundaries() {
        let palette = SYSTEM_COLORS;

        // System colors
        assert_eq!(indexed_to_rgb(0, &palette), palette[0]);
        assert_eq!(indexed_to_rgb(15, &palette), palette[15]);

        // 6x6x6 RGB cube boundaries
        assert_eq!(indexed_to_rgb(16, &palette), [0, 0, 0]);
        assert_eq!(indexed_to_rgb(231, &palette), [255, 255, 255]);

        // Middle of cube (16 + 36*R + 6*G + B) -> R=1, G=2, B=3 -> 16 + 36 + 12 + 3 = 67
        assert_eq!(indexed_to_rgb(67, &palette), [51, 102, 153]);

        // Grayscale ramp boundaries
        assert_eq!(indexed_to_rgb(232, &palette), [8, 8, 8]);
        assert_eq!(indexed_to_rgb(255, &palette), [238, 238, 238]);
    }

    #[test]
    fn a_short_scheme_keeps_no_colour_from_the_one_before_it() {
        let first = palette_from_csv("#112233,#445566,#778899");
        assert_eq!(first[0], [0x11, 0x22, 0x33]);
        assert_eq!(first[1], [0x44, 0x55, 0x66]);
        assert_eq!(first[2], [0x77, 0x88, 0x99]);
        assert_eq!(
            &first[3..],
            &SYSTEM_COLORS[3..],
            "the rest is the default set"
        );

        // The second scheme is built fresh; no slot can carry the first one.
        let second = palette_from_csv("#aabbcc");
        assert_eq!(second[0], [0xaa, 0xbb, 0xcc]);
        for (i, colour) in second.iter().enumerate().skip(1) {
            assert_eq!(*colour, SYSTEM_COLORS[i], "index {i} must not inherit");
        }
    }

    #[test]
    fn a_malformed_entry_keeps_the_default_in_its_slot() {
        let palette = palette_from_csv("#112233, red, #44556, #zzzzzz,#445566");
        assert_eq!(palette[0], [0x11, 0x22, 0x33]);
        assert_eq!(palette[1], SYSTEM_COLORS[1]);
        assert_eq!(palette[2], SYSTEM_COLORS[2]);
        assert_eq!(palette[3], SYSTEM_COLORS[3]);
        assert_eq!(palette[4], [0x44, 0x55, 0x66]);
        assert_eq!(&palette[5..], &SYSTEM_COLORS[5..]);
    }

    #[test]
    fn entries_after_the_sixteenth_are_ignored() {
        let csv = (0..20)
            .map(|i| format!("#{:02x}{:02x}{:02x}", i, i, i))
            .collect::<Vec<_>>()
            .join(",");
        let palette = palette_from_csv(&csv);
        assert_eq!(palette[0], [0, 0, 0]);
        assert_eq!(palette[15], [15, 15, 15]);
        assert_eq!(palette.len(), 16);
    }

    #[test]
    fn palette_resolve_separates_foreground_from_white() {
        let mut palette = Palette::system();
        palette.foreground = [1, 2, 3];
        palette.background = [4, 5, 6];
        palette.ansi[7] = [200, 200, 200];
        assert_eq!(
            palette.resolve(&Color::Named(NamedColor::Foreground)),
            [1, 2, 3]
        );
        assert_eq!(
            palette.resolve(&Color::Named(NamedColor::Background)),
            [4, 5, 6]
        );
        assert_eq!(
            palette.resolve(&Color::Named(NamedColor::White)),
            [200, 200, 200],
            "the ANSI white and the default foreground are different colours"
        );
        assert_eq!(
            palette.resolve(&Color::Indexed(1)),
            palette.ansi[1],
            "an indexed colour still reads the ANSI array"
        );
    }

    #[test]
    fn named_bg_fg_uses_palette() {
        let palette = SYSTEM_COLORS;
        // Background should use palette[0], Foreground should use palette[7]
        assert_eq!(named_to_rgb(&NamedColor::Background, &palette), palette[0]);
        assert_eq!(named_to_rgb(&NamedColor::Foreground, &palette), palette[7]);
        // Verify they are NOT the DEFAULT_BG/DEFAULT_FG constants
        assert_ne!(
            named_to_rgb(&NamedColor::Background, &palette),
            CellInfo::DEFAULT_BG,
            "Background should use palette, not hardcoded DEFAULT_BG"
        );
        assert_ne!(
            named_to_rgb(&NamedColor::Foreground, &palette),
            CellInfo::DEFAULT_FG,
            "Foreground should use palette, not hardcoded DEFAULT_FG"
        );
    }
}
