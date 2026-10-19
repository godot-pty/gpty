//! The FFmpeg build recipe and the runtime allowlists are two halves of one
//! policy: the recipe decides what can be decoded, the Rust lists decide what
//! may be. A format added to one and not the other is a file that opens and
//! then fails, so this test reads the shipped component list and checks both
//! directions.

use std::collections::BTreeSet;

use gpty_media::{
    ALLOWED_AUDIO_CODECS, ALLOWED_DEMUXERS, ALLOWED_VIDEO_CODECS, audio_codec_allowed,
    video_codec_allowed,
};

const COMPONENTS: &str = include_str!("../components.txt");

fn component(name: &str) -> BTreeSet<&'static str> {
    let line = COMPONENTS
        .lines()
        .find_map(|line| line.strip_prefix(&format!("{name}=")))
        .unwrap_or_else(|| panic!("components.txt has no {name}= line"));
    line.split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .collect()
}

#[test]
fn every_runtime_demuxer_is_built() {
    let built = component("demuxers");
    for demuxer in ALLOWED_DEMUXERS {
        assert!(
            built.contains(demuxer),
            "demuxer {demuxer:?} is allowed at runtime but not built"
        );
    }
}

#[test]
fn every_runtime_codec_is_built() {
    let built = component("decoders");
    for codec in ALLOWED_VIDEO_CODECS.iter().chain(ALLOWED_AUDIO_CODECS) {
        assert!(
            built.contains(codec),
            "codec {codec:?} is allowed at runtime but not built"
        );
    }
    // The runtime accepts any pcm_* name; the build must ship the concrete
    // PCM variants the demuxers can produce.
    assert!(built.iter().any(|codec| codec.starts_with("pcm_")));
}

#[test]
fn every_built_codec_is_allowed() {
    for codec in component("decoders") {
        assert!(
            video_codec_allowed(codec) || audio_codec_allowed(codec),
            "decoder {codec:?} is built but no runtime list accepts it"
        );
    }
}

#[test]
fn every_built_parser_is_a_known_parser() {
    // Parsers are not a runtime decision (FFmpeg chooses them), but an empty
    // or malformed list silently removes the ability to parse a stream.
    let parsers = component("parsers");
    assert!(!parsers.is_empty());
    for parser in parsers {
        assert!(!parser.contains(' '), "parser {parser:?} has whitespace");
    }
}
