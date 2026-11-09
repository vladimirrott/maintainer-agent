//! JSON text exactly as Python's `json.dump(obj, f, indent=2)` writes it.
//!
//! The merge gate signs the bytes that `json.dump(indent=2)` produced, so the
//! signature is only checkable by a program that writes the same bytes. The
//! rules, each pinned by a test below:
//!
//! - Keys keep the order they were inserted in. Nothing is sorted.
//! - Two spaces of indent, `,` then a newline between items, `": "` between a
//!   key and its value, and no newline after the last byte.
//! - `{}` and `[]` for empty containers, on one line.
//! - `ensure_ascii` is on: every character outside space to `~` becomes a
//!   `\uXXXX` escape with lower-case hex, so DEL (U+007F) is `\u007f` and a
//!   character above U+FFFF is a surrogate pair. `"`, `\`, newline, carriage
//!   return, tab, backspace and form feed use their short escapes.
//! - Integers print as written; floats print as Python's `repr` does.
//!
//! Known divergence (plan decision: preserved where the gate can hit it, listed
//! where it cannot): Python accepts `NaN`, `Infinity` and lone surrogate escapes
//! when it reads JSON, and `serde_json` refuses them. A receipt holding one is
//! reported as not readable by the Rust side while the bash gate would read it.
//! Only a holder of the signing key can write such a receipt.

use serde_json::Value;
use std::fmt::Write as _;

/// The text `json.dumps(value, indent=2)` gives for `value`.
#[must_use]
pub fn dumps(value: &Value) -> String {
    let mut out = String::new();
    write_value(&mut out, value, 0);
    out
}

fn write_value(out: &mut String, value: &Value, depth: usize) {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(true) => out.push_str("true"),
        Value::Bool(false) => out.push_str("false"),
        Value::Number(number) => out.push_str(&number_text(&number.to_string())),
        Value::String(text) => write_string(out, text),
        Value::Array(items) => {
            if items.is_empty() {
                out.push_str("[]");
                return;
            }
            out.push('[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                newline(out, depth + 1);
                write_value(out, item, depth + 1);
            }
            newline(out, depth);
            out.push(']');
        }
        Value::Object(map) => {
            if map.is_empty() {
                out.push_str("{}");
                return;
            }
            out.push('{');
            for (index, (key, item)) in map.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                newline(out, depth + 1);
                write_string(out, key);
                out.push_str(": ");
                write_value(out, item, depth + 1);
            }
            newline(out, depth);
            out.push('}');
        }
    }
}

fn newline(out: &mut String, depth: usize) {
    out.push('\n');
    for _ in 0..depth {
        out.push_str("  ");
    }
}

fn write_string(out: &mut String, text: &str) {
    out.push('"');
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            ' '..='~' => out.push(c),
            _ => {
                let mut units = [0u16; 2];
                for unit in c.encode_utf16(&mut units) {
                    // Writing to a String cannot fail.
                    let _ = write!(out, "\\u{unit:04x}");
                }
            }
        }
    }
    out.push('"');
}

/// A number as Python prints it, from the text the JSON had.
///
/// A token with a fraction or an exponent is a Python `float` and prints as its
/// `repr`; any other token is an `int` and prints as written, except `-0`,
/// which Python reads as the integer 0.
pub(crate) fn number_text(token: &str) -> String {
    if token.contains(['.', 'e', 'E']) {
        match token.parse::<f64>() {
            Ok(value) => float_repr(value),
            // A token serde_json accepted always parses as f64.
            Err(_) => token.to_string(),
        }
    } else if token == "-0" {
        "0".to_string()
    } else {
        token.to_string()
    }
}

/// Python's `repr(float)`: the shortest digits that read back to the same
/// value, in fixed notation when the decimal exponent is between -4 and 15 and
/// in `d.ddde+XX` notation otherwise.
#[must_use]
pub fn float_repr(value: f64) -> String {
    if value.is_nan() {
        return "NaN".to_string();
    }
    if value.is_infinite() {
        return if value < 0.0 { "-Infinity" } else { "Infinity" }.to_string();
    }
    if value == 0.0 {
        return if value.is_sign_negative() { "-0.0" } else { "0.0" }.to_string();
    }
    let sign = if value < 0.0 { "-" } else { "" };
    // Rust's `{:e}` prints the shortest digits that round-trip: "1.2345e-5".
    let scientific = format!("{:e}", value.abs());
    let (mantissa, exponent) = scientific.split_once('e').unwrap_or((&scientific, "0"));
    let exponent: i32 = exponent.parse().unwrap_or(0);
    let digits: String = mantissa.chars().filter(char::is_ascii_digit).collect();
    let point = exponent + 1; // digits before the decimal point, as Python counts them
    let width = i32::try_from(digits.len()).unwrap_or(i32::MAX);
    if (-3..=16).contains(&point) {
        if point <= 0 {
            let zeros = "0".repeat(usize::try_from(-point).unwrap_or(0));
            format!("{sign}0.{zeros}{digits}")
        } else if width <= point {
            let zeros = "0".repeat(usize::try_from(point - width).unwrap_or(0));
            format!("{sign}{digits}{zeros}.0")
        } else {
            let split = usize::try_from(point).unwrap_or(0);
            format!("{sign}{}.{}", &digits[..split], &digits[split..])
        }
    } else {
        let (first, rest) = digits.split_at(1);
        let fraction = if rest.is_empty() { String::new() } else { format!(".{rest}") };
        let exp_sign = if exponent < 0 { '-' } else { '+' };
        format!("{sign}{first}{fraction}e{exp_sign}{:02}", exponent.abs())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn parse(text: &str) -> Value {
        serde_json::from_str(text).unwrap()
    }

    #[test]
    fn keys_keep_the_order_they_were_inserted_in() {
        let value = parse(r#"{"b": 1, "a": 2, "c": 3}"#);
        assert_eq!(dumps(&value), "{\n  \"b\": 1,\n  \"a\": 2,\n  \"c\": 3\n}");
    }

    #[test]
    fn indent_is_two_spaces_and_nested_objects_and_arrays_indent_further() {
        let value = parse(r#"{"o": {"k": [1, {"x": null}]}, "t": true, "f": false}"#);
        let want = "{\n  \"o\": {\n    \"k\": [\n      1,\n      {\n        \"x\": null\n      }\n    ]\n  },\n  \"t\": true,\n  \"f\": false\n}";
        assert_eq!(dumps(&value), want);
    }

    #[test]
    fn empty_containers_print_on_one_line() {
        let value = parse(r#"{"a": {}, "b": []}"#);
        assert_eq!(dumps(&value), "{\n  \"a\": {},\n  \"b\": []\n}");
    }

    #[test]
    fn the_text_has_no_trailing_newline() {
        assert!(!dumps(&json!({"a": 1})).ends_with('\n'));
    }

    #[test]
    fn non_ascii_characters_become_lower_case_u_escapes() {
        let value = json!({ "p": "caf\u{e9} \u{20ac} \u{ff}" });
        assert_eq!(dumps(&value), "{\n  \"p\": \"caf\\u00e9 \\u20ac \\u00ff\"\n}");
    }

    #[test]
    fn a_character_above_ffff_is_a_surrogate_pair() {
        // U+1F600 is D83D DE00; U+10FFFF is DBFF DFFF.
        let value = json!({ "p": "\u{1F600}\u{10FFFF}" });
        assert_eq!(dumps(&value), "{\n  \"p\": \"\\ud83d\\ude00\\udbff\\udfff\"\n}");
    }

    #[test]
    fn the_short_escapes_are_used_where_python_uses_them() {
        let value = json!({ "p": "\"\\\n\r\t\u{8}\u{c}" });
        assert_eq!(dumps(&value), "{\n  \"p\": \"\\\"\\\\\\n\\r\\t\\b\\f\"\n}");
    }

    #[test]
    fn other_control_characters_and_del_use_the_u_form() {
        let value = json!({ "p": "\u{0}\u{1}\u{1f}\u{7f}\u{80}" });
        assert_eq!(dumps(&value), "{\n  \"p\": \"\\u0000\\u0001\\u001f\\u007f\\u0080\"\n}");
    }

    #[test]
    fn keys_are_escaped_like_values() {
        let value = json!({ "k\u{e9}": 1 });
        assert_eq!(dumps(&value), "{\n  \"k\\u00e9\": 1\n}");
    }

    #[test]
    fn integers_print_as_written_including_beyond_64_bits() {
        let value = parse(r#"{"a": 7, "b": -12, "c": 123456789012345678901234567890, "d": -0}"#);
        assert_eq!(
            dumps(&value),
            "{\n  \"a\": 7,\n  \"b\": -12,\n  \"c\": 123456789012345678901234567890,\n  \"d\": 0\n}"
        );
    }

    #[test]
    fn floats_print_as_python_repr_does() {
        let cases = [
            ("1.0", "1.0"),
            ("1.50", "1.5"),
            ("0.1", "0.1"),
            ("100.0", "100.0"),
            ("1e2", "100.0"),
            ("0.0001", "0.0001"),
            ("0.00001", "1e-05"),
            ("1e-7", "1e-07"),
            ("123456789.123", "123456789.123"),
            ("1e15", "1000000000000000.0"),
            ("1e16", "1e+16"),
            ("1.5e300", "1.5e+300"),
            ("-2.5e-10", "-2.5e-10"),
            ("-0.0", "-0.0"),
            ("0.0", "0.0"),
            ("12345678901234567.0", "1.2345678901234568e+16"),
            ("1e999", "Infinity"),
        ];
        for (input, want) in cases {
            let value = parse(&format!("{{\"n\": {input}}}"));
            assert_eq!(dumps(&value), format!("{{\n  \"n\": {want}\n}}"), "input {input}");
        }
    }

    #[test]
    fn a_duplicate_key_keeps_its_first_position_and_its_last_value() {
        // Python's json.load does the same, and the signature covers the result.
        let value = parse(r#"{"a": 1, "b": 2, "a": 3}"#);
        assert_eq!(dumps(&value), "{\n  \"a\": 3,\n  \"b\": 2\n}");
    }

    #[test]
    fn the_golden_receipt_body_dumps_to_the_bytes_the_gate_wrote() {
        let path = format!(
            "{}/../../../tests/characterization/golden/receipt-asserted.json",
            env!("CARGO_MANIFEST_DIR")
        );
        let golden =
            std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("cannot read {path}: {e}"));
        let value = parse(&golden);
        assert_eq!(dumps(&value), golden);
    }
}
