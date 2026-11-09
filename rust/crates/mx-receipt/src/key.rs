//! The signing key and the HMAC-SHA256 over a receipt body.

use crate::error::ReceiptError;
use hmac::{Hmac, Mac};
use sha2::Sha256;

type HmacSha256 = Hmac<Sha256>;

/// The key that signs and verifies receipts.
///
/// The bash gate reads the key file as text and strips it (Python
/// `Path.read_text().strip().encode()`), so `from_file_bytes` does the same:
/// UTF-8 text, `\r\n` and `\r` read as `\n` (Python's universal newlines), then
/// leading and trailing whitespace removed. Whitespace is Python's
/// `str.isspace`: Unicode `White_Space` plus U+001C to U+001F.
///
/// `Debug` prints no key bytes.
pub struct Key(Vec<u8>);

impl std::fmt::Debug for Key {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Key({} bytes, redacted)", self.0.len())
    }
}

fn is_py_space(c: char) -> bool {
    c.is_whitespace() || ('\u{1c}'..='\u{1f}').contains(&c)
}

impl Key {
    /// The key a key file's bytes name.
    pub fn from_file_bytes(bytes: &[u8]) -> Result<Self, ReceiptError> {
        let text = std::str::from_utf8(bytes).map_err(|_| ReceiptError::KeyNotText)?;
        let text = text.replace("\r\n", "\n").replace('\r', "\n");
        Ok(Self(text.trim_matches(is_py_space).as_bytes().to_vec()))
    }

    /// The lower-case hex HMAC-SHA256 of `payload`.
    #[must_use]
    pub fn sign(&self, payload: &[u8]) -> String {
        let mut mac = self.mac();
        mac.update(payload);
        hex(&mac.finalize().into_bytes())
    }

    /// True when `signature` is the HMAC-SHA256 of `payload` under this key.
    ///
    /// The comparison is `Mac::verify_slice`, which compares in constant time.
    /// A signature that is not 64 lower-case hex digits cannot equal the
    /// lower-case hex string the bash gate compares against, so it is a
    /// mismatch.
    #[must_use]
    pub fn verify(&self, payload: &[u8], signature: &str) -> bool {
        let Some(expected) = unhex(signature) else { return false };
        let mut mac = self.mac();
        mac.update(payload);
        mac.verify_slice(&expected).is_ok()
    }

    fn mac(&self) -> HmacSha256 {
        // HMAC accepts a key of any length, the empty key included, as Python does.
        HmacSha256::new_from_slice(&self.0)
            .unwrap_or_else(|_| unreachable!("HMAC takes any key length"))
    }
}

fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push(char::from(DIGITS[usize::from(byte >> 4)]));
        out.push(char::from(DIGITS[usize::from(byte & 15)]));
    }
    out
}

fn unhex(text: &str) -> Option<Vec<u8>> {
    let bytes = text.as_bytes();
    if bytes.len() != 64 {
        return None;
    }
    let nibble = |b: u8| match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        _ => None,
    };
    bytes.chunks(2).map(|pair| Some(nibble(pair[0])? << 4 | nibble(pair[1])?)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn golden_key_bytes() -> Vec<u8> {
        let path = format!(
            "{}/../../../tests/characterization/golden/receipt.key",
            env!("CARGO_MANIFEST_DIR")
        );
        std::fs::read(&path).unwrap_or_else(|e| panic!("cannot read {path}: {e}"))
    }

    #[test]
    fn rfc_4231_test_case_2_gives_the_published_tag() {
        // HMAC-SHA256, key "Jefe", data "what do ya want for nothing?".
        let key = Key::from_file_bytes(b"Jefe").unwrap();
        assert_eq!(
            key.sign(b"what do ya want for nothing?"),
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        );
    }

    #[test]
    fn the_golden_key_file_is_read_with_its_newline_stripped() {
        let key = Key::from_file_bytes(&golden_key_bytes()).unwrap();
        let bare = Key::from_file_bytes(b"characterization-key-0001-not-a-secret").unwrap();
        assert_eq!(key.sign(b"x"), bare.sign(b"x"));
    }

    #[test]
    fn whitespace_around_the_key_is_stripped_and_inside_it_is_kept() {
        let padded = Key::from_file_bytes(b"\n  a b  \n\n").unwrap();
        let tight = Key::from_file_bytes(b"a b").unwrap();
        let other = Key::from_file_bytes(b"ab").unwrap();
        assert_eq!(padded.sign(b"x"), tight.sign(b"x"));
        assert_ne!(padded.sign(b"x"), other.sign(b"x"));
    }

    #[test]
    fn python_whitespace_that_rust_trim_would_keep_is_stripped() {
        // U+001C to U+001F count as whitespace to Python's str.strip().
        let padded = Key::from_file_bytes(b"\x1ckey\x1f").unwrap();
        let tight = Key::from_file_bytes(b"key").unwrap();
        assert_eq!(padded.sign(b"x"), tight.sign(b"x"));
    }

    #[test]
    fn carriage_returns_read_as_newlines_like_python_text_mode() {
        let crlf = Key::from_file_bytes(b"a\r\nb\rc").unwrap();
        let lf = Key::from_file_bytes(b"a\nb\nc").unwrap();
        assert_eq!(crlf.sign(b"x"), lf.sign(b"x"));
    }

    #[test]
    fn a_key_that_is_not_utf8_is_refused() {
        assert_eq!(Key::from_file_bytes(b"\xff\xfe").unwrap_err(), ReceiptError::KeyNotText);
    }

    #[test]
    fn an_empty_key_signs_like_python_hmac_with_an_empty_key() {
        // Python: hmac.new(b"", b"abc", hashlib.sha256).hexdigest()
        let key = Key::from_file_bytes(b"  \n").unwrap();
        assert_eq!(
            key.sign(b"abc"),
            "fd7adb152c05ef80dccf50a1fa4c05d5a3ec6da95575fc312ae7c5d091836351"
        );
    }

    #[test]
    fn verify_accepts_its_own_signature_and_refuses_a_changed_payload_or_key() {
        let key = Key::from_file_bytes(b"k1").unwrap();
        let sig = key.sign(b"payload");
        assert!(key.verify(b"payload", &sig));
        assert!(!key.verify(b"payloae", &sig));
        assert!(!Key::from_file_bytes(b"k2").unwrap().verify(b"payload", &sig));
    }

    #[test]
    fn verify_refuses_upper_case_hex_and_wrong_lengths_as_the_string_compare_does() {
        let key = Key::from_file_bytes(b"k1").unwrap();
        let sig = key.sign(b"payload");
        assert!(!key.verify(b"payload", &sig.to_uppercase()));
        assert!(!key.verify(b"payload", &sig[..62]));
        assert!(!key.verify(b"payload", &format!("{sig}00")));
        assert!(!key.verify(b"payload", ""));
        assert!(!key.verify(b"payload", &"g".repeat(64)));
    }

    #[test]
    fn debug_does_not_print_the_key() {
        let key = Key::from_file_bytes(b"super-secret-value").unwrap();
        let shown = format!("{key:?}");
        assert!(!shown.contains("super-secret"), "{shown}");
    }

    /// `Mac::verify_slice` compares in constant time. Behaviour cannot show it:
    /// `==` on two byte strings gives the same answers, only slower on a long
    /// common prefix. So this test reads the source and demands that `verify`
    /// goes through `verify_slice` and holds no `==` or `!=` on the signature.
    /// A mutant that swaps in `==` fails here; no behavioural test can catch it.
    #[test]
    fn verify_uses_the_constant_time_comparison_and_no_equals_on_the_signature() {
        let source = include_str!("key.rs");
        let body = source.split("pub fn verify").nth(1).unwrap().split("fn mac").next().unwrap();
        assert!(body.contains("verify_slice"), "verify must call Mac::verify_slice");
        assert!(!body.contains("=="), "verify must not compare with ==");
        assert!(!body.contains("!="), "verify must not compare with !=");
    }
}
