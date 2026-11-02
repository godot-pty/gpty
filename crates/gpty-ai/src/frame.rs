//! One bounded line from a backend child's stdout.
//!
//! `tokio::io::Lines` (and `BufReader::read_line`) buffer a whole line before
//! returning it, so a size check applied afterwards bounds nothing: a wedged or
//! hostile adapter that streams bytes without a newline grows the buffer for
//! the entire turn timeout. Filling and consuming in bounded steps caps the
//! memory instead.
//!
//! Both process backends read their child's stdout through this one function.
//! The CLI bridge had the bound (`cli.rs`'s `read_frame`) and the OMP RPC
//! stream did not - a backend that never sent a newline grew the Inspector's
//! process without limit - so the difference was never the protocol, just
//! which function each backend happened to call.

use tokio::io::{AsyncBufRead, AsyncBufReadExt};

/// Read one newline-terminated frame, failing as soon as its content exceeds
/// `limit` bytes (the terminating newline is not counted). `label` names the
/// backend in the error the Inspector shows.
///
/// The trailing `\n` (and a `\r` before it) is stripped. An unterminated final
/// line at EOF is still delivered; `Ok(None)` is EOF.
///
/// Public so the workspace's fuzz harness (`fuzz/fuzz_targets/ai_frame.rs`)
/// drives the exact function the backends use; the alternative — a copy of the
/// loop in the target — would fuzz a reader that ships to nobody.
pub async fn read_frame<R>(
    reader: &mut R,
    limit: usize,
    label: &str,
) -> Result<Option<String>, String>
where
    R: AsyncBufRead + Unpin,
{
    let mut line: Vec<u8> = Vec::new();
    loop {
        let chunk = reader
            .fill_buf()
            .await
            .map_err(|e| format!("{label} backend read: {e}"))?;
        if chunk.is_empty() {
            // EOF: a final unterminated line is still delivered.
            break;
        }
        let take = match chunk.iter().position(|&b| b == b'\n') {
            Some(pos) => pos + 1,
            None => chunk.len(),
        };
        line.extend_from_slice(&chunk[..take]);
        reader.consume(take);
        let content = line.len() - usize::from(line.last() == Some(&b'\n'));
        if content > limit {
            return Err(format!("{label} backend frame exceeds {limit} bytes"));
        }
        if line.last() == Some(&b'\n') {
            break;
        }
    }
    if line.is_empty() {
        return Ok(None);
    }
    // An unterminated final line has no newline to strip.
    if line.last() == Some(&b'\n') {
        line.pop();
        if line.last() == Some(&b'\r') {
            line.pop();
        }
    }
    String::from_utf8(line)
        .map(Some)
        .map_err(|e| format!("{label} backend frame not UTF-8: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn buffered(bytes: &[u8]) -> tokio::io::BufReader<&[u8]> {
        tokio::io::BufReader::new(bytes)
    }

    #[tokio::test]
    async fn lines_are_delivered_in_order_and_crlf_is_stripped() {
        let mut reader = buffered(b"first\r\nsecond\nlast");
        assert_eq!(
            read_frame(&mut reader, 64, "test").await.unwrap(),
            Some("first".to_string())
        );
        assert_eq!(
            read_frame(&mut reader, 64, "test").await.unwrap(),
            Some("second".to_string())
        );
        // An unterminated final line is still a frame.
        assert_eq!(
            read_frame(&mut reader, 64, "test").await.unwrap(),
            Some("last".to_string())
        );
        assert_eq!(read_frame(&mut reader, 64, "test").await.unwrap(), None);
    }

    #[tokio::test]
    async fn a_line_over_the_limit_is_refused_instead_of_buffered() {
        // No newline at all: `Lines` would hold all of it before returning.
        let oversized = vec![b'x'; 4096];
        let mut reader = buffered(&oversized);
        let error = read_frame(&mut reader, 64, "test").await.unwrap_err();
        assert!(error.contains("exceeds 64 bytes"), "{error}");
    }

    #[tokio::test]
    async fn a_limit_equal_to_the_line_is_accepted() {
        let mut reader = buffered(b"abcd\n");
        assert_eq!(
            read_frame(&mut reader, 4, "test").await.unwrap(),
            Some("abcd".to_string())
        );
    }
}
