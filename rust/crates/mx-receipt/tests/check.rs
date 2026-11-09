//! `Stored::check`: the gate's `receipt_check`, case by case.
mod common;
use common::*;
use mx_receipt::{Kind, ReceiptError, SigFault, Stamp, Stored, pyjson};
use serde_json::{Map, Value};

fn check(
    bytes: &[u8],
    pr: &str,
    unattended: bool,
) -> Result<mx_receipt::Receipt<mx_receipt::Signed>, ReceiptError> {
    Stored::parse(bytes)?.check(&key(), pr, unattended)
}

#[test]
fn a_receipt_with_no_signature_is_unsigned() {
    let bytes = pyjson::dumps(&Value::Object(body(&[]))).into_bytes();
    assert_eq!(check(&bytes, "7", false).err(), Some(ReceiptError::Unsigned));
}

#[test]
fn an_empty_signature_is_unsigned_and_a_non_string_signature_is_a_mismatch() {
    let empty = pyjson::dumps(&Value::Object(body(&[("signature", Value::String(String::new()))])))
        .into_bytes();
    assert_eq!(check(&empty, "7", false).err(), Some(ReceiptError::Unsigned));
    for bad in [Value::Null, Value::from(5), Value::Bool(true), Value::Array(vec![])] {
        let bytes = pyjson::dumps(&Value::Object(body(&[("signature", bad.clone())]))).into_bytes();
        assert_eq!(check(&bytes, "7", false).err(), Some(ReceiptError::SignatureMismatch), "{bad}");
    }
}

#[test]
fn text_that_is_not_a_json_object_is_not_json() {
    for text in ["this is not json", "[1, 2]", "\"s\"", "", "{\"a\": 1} trailing"] {
        let error = Stored::parse(text.as_bytes()).unwrap_err();
        assert!(matches!(error, ReceiptError::NotJson { .. }), "{text:?}: {error:?}");
    }
}

#[test]
fn a_body_edited_after_signing_is_a_mismatch_for_every_field() {
    let good = signed(body(&[]));
    assert!(check(&good, "7", false).is_ok());
    let mut ran = 0;
    for (name, value) in [
        ("head", Value::String("0".repeat(40))),
        ("proof", Value::String("q".into())),
        ("kind", Value::String("dependency".into())),
        ("recorded_by", Value::String("someone".into())),
        ("recorded_at", Value::String("2030-01-01T00:00:00+00:00".into())),
    ] {
        let mut map = parse(std::str::from_utf8(&good).unwrap());
        map.insert(name.into(), value);
        let bytes = pyjson::dumps(&Value::Object(map)).into_bytes();
        assert_eq!(
            check(&bytes, "7", false).err(),
            Some(ReceiptError::SignatureMismatch),
            "field {name}"
        );
        ran += 1;
    }
    assert_eq!(ran, 5);
}

#[test]
fn the_signature_is_checked_before_the_pull_request() {
    let mut map = body(&[]);
    map.insert("pr".into(), Value::from(8));
    let tampered = {
        let mut m = parse(std::str::from_utf8(&signed(body(&[]))).unwrap());
        m.insert("pr".into(), Value::from(8));
        pyjson::dumps(&Value::Object(m)).into_bytes()
    };
    assert_eq!(check(&tampered, "7", false).err(), Some(ReceiptError::SignatureMismatch));
    // The same body signed properly names pull request 8, and is refused for 7.
    let honest = signed(map);
    assert_eq!(
        check(&honest, "7", false).err(),
        Some(ReceiptError::WrongPullRequest { wanted: "7".into(), found: "8".into() })
    );
}

#[test]
fn a_copied_receipt_is_refused_for_the_other_pull_request() {
    // cp 7.json 8.json: the signature holds, the filename is not signed, the pr field is.
    let seven = signed(body(&[]));
    let error = check(&seven, "8", false).err();
    assert_eq!(
        error,
        Some(ReceiptError::WrongPullRequest { wanted: "8".into(), found: "7".into() })
    );
}

#[test]
fn pr_is_compared_as_text_so_007_does_not_match_a_receipt_for_7() {
    let seven = signed(body(&[]));
    assert!(check(&seven, "007", false).is_err());
    assert!(check(&seven, "7", false).is_ok());
}

#[test]
fn a_signed_receipt_with_no_pr_field_names_none() {
    let mut map = body(&[]);
    map.shift_remove("pr");
    let error = check(&signed(map), "7", false).err();
    assert_eq!(
        error,
        Some(ReceiptError::WrongPullRequest { wanted: "7".into(), found: "<none>".into() })
    );
}

#[test]
fn an_unattended_run_spends_observed_and_dependency_and_nothing_else() {
    let mut results = Vec::new();
    for kind in ["observed", "dependency", "asserted", "anything-else"] {
        let mut map = body(&[]);
        map.insert("kind".into(), Value::String(kind.into()));
        results.push((kind, check(&signed(map), "7", true).is_ok()));
    }
    assert_eq!(
        results,
        vec![
            ("observed", true),
            ("dependency", true),
            ("asserted", false),
            ("anything-else", false)
        ]
    );
}

#[test]
fn an_unattended_refusal_names_the_kind() {
    let mut map = body(&[]);
    map.insert("kind".into(), Value::String("asserted".into()));
    let error = check(&signed(map), "7", true).err();
    assert_eq!(error, Some(ReceiptError::KindNotSpendable { kind: "asserted".into() }));
}

#[test]
fn an_attended_caller_spends_any_kind_and_unknown_kinds_get_the_asserted_notice() {
    let mut map = body(&[]);
    map.insert("kind".into(), Value::String("anything-else".into()));
    let receipt = check(&signed(map), "7", false).unwrap();
    assert_eq!(receipt.body().kind, Kind::Other("anything-else".into()));
    assert!(receipt.kind_notice().unwrap().starts_with("the receipt is ASSERTED, not observed"));
}

#[test]
fn the_kind_notices_say_what_merge_prints() {
    let observed = check(&signed(body(&[])), "7", false).unwrap();
    assert_eq!(observed.kind_notice(), None);
    let mut dep = body(&[]);
    dep.insert("kind".into(), Value::String("dependency".into()));
    let dep = check(&signed(dep), "7", false).unwrap();
    assert_eq!(
        dep.kind_notice(),
        Some(
            "the receipt is a DEPENDENCY receipt: nothing but dependency metadata\n     changed, and every action pin was checked against its tag"
        )
    );
    let mut asserted = body(&[]);
    asserted.insert("kind".into(), Value::String("asserted".into()));
    let asserted = check(&signed(asserted), "7", false).unwrap();
    assert_eq!(
        asserted.kind_notice(),
        Some(
            "the receipt is ASSERTED, not observed: it records a claim a\n     human made, and nothing here checked it"
        )
    );
}

#[test]
fn a_signed_receipt_with_a_field_the_model_does_not_know_is_refused_as_the_wrong_shape() {
    // Stricter than bash, which reads fields by name (see the receipt module docs).
    let error = check(&signed(body(&[("surprise", Value::from(1))])), "7", false).err();
    assert!(matches!(error, Some(ReceiptError::Shape { .. })), "{error:?}");
}

#[test]
fn the_signature_may_sit_anywhere_in_the_file_because_it_is_removed_in_place() {
    // Python's d.pop("signature") keeps the order of the other keys.
    let rest = body(&[]);
    let signature = key().sign(pyjson::dumps(&Value::Object(rest.clone())).as_bytes());
    let mut in_the_middle = Map::new();
    for (index, (name, value)) in rest.iter().enumerate() {
        if index == 2 {
            in_the_middle.insert("signature".into(), Value::String(signature.clone()));
        }
        in_the_middle.insert(name.clone(), value.clone());
    }
    let bytes = pyjson::dumps(&Value::Object(in_the_middle)).into_bytes();
    assert!(check(&bytes, "7", false).is_ok());
}

#[test]
fn a_duplicate_key_reads_as_python_reads_it() {
    // json.load keeps the first position and the last value, and signs that.
    let good = signed(body(&[]));
    let text = std::str::from_utf8(&good).unwrap().replacen(
        "\"proof\": \"p\"",
        "\"proof\": \"zz\",\n  \"proof\": \"p\"",
        1,
    );
    assert_eq!(text.matches("\"proof\"").count(), 2);
    assert!(check(text.as_bytes(), "7", false).is_ok());
}

#[test]
fn verify_signature_reports_the_bash_codes() {
    let unsigned = Stored::parse(pyjson::dumps(&Value::Object(body(&[]))).as_bytes()).unwrap();
    assert_eq!(unsigned.verify_signature(&key()), Err(SigFault::Unsigned));
    let good = Stored::parse(&signed(body(&[]))).unwrap();
    assert_eq!(good.verify_signature(&key()), Ok(()));
    let other_key = mx_receipt::Key::from_file_bytes(b"another key").unwrap();
    assert_eq!(good.verify_signature(&other_key), Err(SigFault::Mismatch));
}

#[test]
fn field_text_reads_as_python_prints() {
    let stored = Stored::parse(br#"{"a": 7, "b": true, "c": null, "d": "x", "e": 1.50}"#).unwrap();
    let got: Vec<String> =
        ["a", "b", "c", "d", "e", "missing"].iter().map(|f| stored.field_text(f, "dflt")).collect();
    assert_eq!(got, vec!["7", "True", "None", "x", "1.5", "dflt"]);
}

fn suites(extra: &[(&str, Value)]) -> Vec<String> {
    check(&signed(body(extra)), "7", false).unwrap().suites()
}

#[test]
fn suites_come_from_proofs_in_order_without_repeats_and_without_empty_names() {
    let proofs = serde_json::json!([{"suite": "rust"}, {"suite": "python"}, {"suite": "rust"}, {"suite": ""}]);
    // A receipt with proofs of this loose shape is not the gate's own, so read it raw.
    let stored = Stored::parse(&signed(body(&[("proofs", proofs)]))).unwrap();
    assert_eq!(stored.suites(), vec!["rust", "python"]);
}

#[test]
fn a_receipt_with_no_proofs_falls_back_to_its_flat_suite() {
    assert_eq!(suites(&[("suite", Value::String("rust".into()))]), vec!["rust"]);
    assert!(suites(&[]).is_empty());
}

#[test]
fn partial_is_true_only_for_true() {
    let mut seen = Vec::new();
    for value in [
        Value::Bool(true),
        Value::Bool(false),
        Value::String("true".into()),
        Value::String("no".into()),
        Value::from(1),
    ] {
        let receipt = check(&signed(body(&[("partial", value.clone())])), "7", false);
        // A non-boolean `partial` is the wrong shape for the typed model, so read it raw.
        let raw = Stored::parse(&signed(body(&[("partial", value.clone())]))).unwrap();
        seen.push((value.to_string(), raw.is_partial(), receipt.is_ok()));
    }
    assert_eq!(
        seen,
        vec![
            ("true".into(), true, true),
            ("false".into(), false, true),
            ("\"true\"".into(), true, false),
            ("\"no\"".into(), false, false),
            ("1".into(), false, false),
        ]
    );
}

#[test]
fn an_unattended_assertion_and_a_short_head_are_refused_before_anything_is_built() {
    use mx_receipt::Receipt;
    let stamp = Stamp::new("t", "u");
    assert_eq!(
        Receipt::asserted(7, "abcdef0", "p", &stamp, true).err(),
        Some(ReceiptError::UnattendedAssert)
    );
    assert_eq!(
        Receipt::asserted(7, "abcdef", "p", &stamp, false).err(),
        Some(ReceiptError::HeadTruncated { head: "abcdef".into() })
    );
    // Seven characters is enough; the head is recorded as typed.
    assert!(Receipt::asserted(7, "abcdef0", "p", &stamp, false).is_ok());
    assert!(Receipt::asserted(7, "not a sha at all", "p", &stamp, false).is_ok());
    // Characters, not bytes: six two-byte characters are still short.
    assert!(
        Receipt::asserted(7, "\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}", "p", &stamp, false).is_err()
    );
    // The unattended refusal comes first, as in bash.
    assert_eq!(
        Receipt::asserted(7, "abc", "p", &stamp, true).err(),
        Some(ReceiptError::UnattendedAssert)
    );
}
