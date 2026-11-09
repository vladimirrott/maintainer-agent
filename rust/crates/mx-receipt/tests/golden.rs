//! The known-answer vector from tests/characterization/golden/ and the
//! variants gate-receipt.sh feeds the bash verifier.
mod common;
use common::*;
use mx_receipt::{Receipt, ReceiptError, Stamp, Stored, pyjson};
use serde_json::{Value, ser::PrettyFormatter};

fn stamp() -> Stamp {
    Stamp::new("2026-01-01T00:00:00+00:00", "fixture-user")
}

fn proof_text() -> String {
    "mutation \"proved\" \u{e9}\nsecond line".to_string()
}

#[test]
fn the_golden_inputs_sign_to_the_golden_bytes_and_signature() {
    let receipt =
        Receipt::asserted(7, GOLDEN_HEAD, &proof_text(), &stamp(), false).unwrap().sign(&key());
    assert_eq!(
        receipt.signature(),
        "d43b8aa35fa30e2d9c5ac8693570fc2b726d649b8c8cf6da64a39c3b57bb6f87"
    );
    assert_eq!(String::from_utf8(receipt.to_bytes()).unwrap(), golden_receipt());
}

#[test]
fn the_golden_receipt_passes_the_gate_check_and_round_trips_to_its_own_bytes() {
    let stored = Stored::parse(golden_receipt().as_bytes()).unwrap();
    let receipt = stored.check(&key(), "7", false).unwrap();
    assert_eq!(receipt.head(), GOLDEN_HEAD);
    assert_eq!(receipt.body().proof, proof_text());
    assert_eq!(receipt.to_bytes(), golden_receipt().as_bytes());
    assert!(!golden_receipt().ends_with('\n'));
}

fn variant(name: &str) -> Vec<u8> {
    let value = serde_json::from_str::<Value>(&golden_receipt()).unwrap();
    let mut map = parse(&golden_receipt());
    match name {
        "compact" => serde_json::to_string(&value).unwrap().into_bytes(),
        "raw-utf8" => serde_json::to_string_pretty(&value).unwrap().into_bytes(),
        "four-space-indent" => {
            let mut out = Vec::new();
            let formatter = PrettyFormatter::with_indent(b"    ");
            let mut serializer = serde_json::Serializer::with_formatter(&mut out, formatter);
            serde::Serialize::serialize(&value, &mut serializer).unwrap();
            out
        }
        "trailing-newline" => format!("{}\n", golden_receipt()).into_bytes(),
        "reordered" => {
            let kind = map.shift_remove("kind").unwrap();
            let mut reordered = serde_json::Map::new();
            reordered.insert("kind".into(), kind);
            reordered.extend(map);
            pyjson::dumps(&Value::Object(reordered)).into_bytes()
        }
        "signature-digit" => {
            let sig = map["signature"].as_str().unwrap().to_string();
            let flipped = format!("{}{}", if sig.starts_with('0') { "1" } else { "0" }, &sig[1..]);
            map.insert("signature".into(), Value::String(flipped));
            pyjson::dumps(&Value::Object(map)).into_bytes()
        }
        "proof-edit" => {
            let edited = map["proof"].as_str().unwrap().replace("proved", "PROVED");
            map.insert("proof".into(), Value::String(edited));
            pyjson::dumps(&Value::Object(map)).into_bytes()
        }
        "pr-edit" => {
            map.insert("pr".into(), Value::from(8));
            pyjson::dumps(&Value::Object(map)).into_bytes()
        }
        other => panic!("unknown variant {other}"),
    }
}

#[test]
fn a_re_serialised_golden_receipt_still_verifies_because_the_check_re_serialises() {
    // gate-receipt.sh: compact, raw-utf8, four-space-indent and trailing-newline all merge.
    let mut ran = 0;
    for name in ["compact", "raw-utf8", "four-space-indent", "trailing-newline"] {
        let bytes = variant(name);
        assert_ne!(
            bytes,
            golden_receipt().as_bytes(),
            "variant {name} must differ from the golden bytes"
        );
        let result = Stored::parse(&bytes).unwrap().check(&key(), "7", false);
        assert!(result.is_ok(), "variant {name}: {:?}", result.err());
        ran += 1;
    }
    assert_eq!(ran, 4, "four variants must have run");
}

#[test]
fn an_edited_or_reordered_golden_receipt_fails_the_signature_check() {
    let mut ran = 0;
    for name in ["signature-digit", "proof-edit", "reordered", "pr-edit"] {
        let result = Stored::parse(&variant(name)).unwrap().check(&key(), "7", false);
        assert_eq!(result.err(), Some(ReceiptError::SignatureMismatch), "variant {name}");
        ran += 1;
    }
    assert_eq!(ran, 4, "four variants must have run");
}

#[test]
fn the_fixture_receipts_the_gate_writer_code_made_match_what_rust_builds() {
    use mx_receipt::{DependencyFacts, FoldBase, Part, plan_fold};
    // tests/fixtures/*.json came from the gate's own writer snippets and signing
    // code (cmd_verify, cmd_verify_deps, receipt_seal) run with the golden key.
    let first = Part {
        suite: "rust".into(),
        units_run: "12".into(),
        filter: "gate::refuses".into(),
        mutation: "s/>=/>/".into(),
        mutated_rc: 101,
        observed_failure: "assertion failed: left == right \u{2192} caf\u{e9}".into(),
    };
    let second = Part {
        suite: "python".into(),
        units_run: "3".into(),
        filter: "test_gate".into(),
        mutation: "s/a/b/".into(),
        mutated_rc: 1,
        observed_failure: "FAILED tests/test_gate.py::test_x".into(),
    };
    let one = Receipt::observed(
        7,
        GOLDEN_HEAD,
        FoldBase::Fresh { note: None },
        &first,
        Some("1"),
        &stamp(),
    )
    .sign(&key());
    let base = plan_fold(Some(&one.to_bytes()), "7", GOLDEN_HEAD, Some("1"), &key()).unwrap();
    let two = Receipt::observed(7, GOLDEN_HEAD, base, &second, Some("1"), &stamp()).sign(&key());
    assert_eq!(String::from_utf8(two.to_bytes()).unwrap(), FIXTURE_OBSERVED);

    let facts = DependencyFacts {
        files: "Cargo.lock (2)".into(),
        changed_lines: 4,
        pins_verified: 2,
        images_verified: 1,
        pip_verified: 0,
    };
    let dependency = Receipt::dependency(9, GOLDEN_HEAD, &facts, &stamp()).sign(&key());
    assert_eq!(String::from_utf8(dependency.to_bytes()).unwrap(), FIXTURE_DEPENDENCY);
}

#[test]
fn the_fixture_receipts_pass_the_gate_check() {
    for (text, pr) in [(FIXTURE_OBSERVED, "7"), (FIXTURE_DEPENDENCY, "9")] {
        let receipt = Stored::parse(text.as_bytes()).unwrap().check(&key(), pr, true).unwrap();
        assert_eq!(receipt.to_bytes(), text.as_bytes());
    }
}
