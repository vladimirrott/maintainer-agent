//! Part mode: `plan_fold` and the receipt `Receipt::observed` builds from it.
mod common;
use common::*;
use mx_receipt::{
    FoldBase, Part, Receipt, ReceiptError, SigFault, Stamp, Stored, plan_fold, pyjson,
};
use serde_json::Value;

fn stamp() -> Stamp {
    Stamp::new("2026-01-01T00:00:00+00:00", "fixture-user")
}

fn part(suite: &str, units: &str, rc: i32) -> Part {
    Part {
        suite: suite.into(),
        units_run: units.into(),
        filter: format!("{suite}_filter"),
        mutation: format!("s/{suite}/x/"),
        mutated_rc: rc,
        observed_failure: format!("{suite} failed"),
    }
}

fn fresh() -> FoldBase {
    FoldBase::Fresh { note: None }
}

fn build(base: FoldBase, p: &Part, verify_part: Option<&str>) -> Vec<u8> {
    Receipt::observed(7, GOLDEN_HEAD, base, p, verify_part, &stamp()).sign(&key()).to_bytes()
}

fn fold_in(prior: &[u8], p: &Part) -> Vec<u8> {
    let base = plan_fold(Some(prior), "7", GOLDEN_HEAD, Some("1"), &key()).unwrap();
    build(base, p, Some("1"))
}

fn field(bytes: &[u8], name: &str) -> Value {
    parse(std::str::from_utf8(bytes).unwrap())[name].clone()
}

#[test]
fn a_plain_verify_never_reads_the_receipt_on_disk() {
    // The file would fail every check; with no VERIFY_PART it is not even parsed.
    for verify_part in [None, Some("")] {
        let base = plan_fold(Some(b"not json"), "7", GOLDEN_HEAD, verify_part, &key()).unwrap();
        assert_eq!(base, fresh());
    }
}

#[test]
fn part_mode_with_no_file_starts_a_new_receipt_without_a_note() {
    assert_eq!(plan_fold(None, "7", GOLDEN_HEAD, Some("1"), &key()).unwrap(), fresh());
}

#[test]
fn a_receipt_for_another_head_starts_a_new_one_and_says_so() {
    let prior = build(fresh(), &part("rust", "1", 1), Some("1"));
    let base = plan_fold(Some(&prior), "7", &"b".repeat(40), Some("1"), &key()).unwrap();
    let note = format!(
        "the receipt on disk is for #7 at {}, not this head; starting a new one",
        &GOLDEN_HEAD[..8]
    );
    assert_eq!(base, FoldBase::Fresh { note: Some(note) });
}

#[test]
fn a_receipt_for_another_pull_request_starts_a_new_one() {
    let prior = build(fresh(), &part("rust", "1", 1), Some("1"));
    let base = plan_fold(Some(&prior), "8", GOLDEN_HEAD, Some("1"), &key()).unwrap();
    assert!(matches!(base, FoldBase::Fresh { note: Some(_) }));
}

#[test]
fn an_unreadable_prior_file_reads_as_no_pr_and_no_head() {
    let base = plan_fold(Some(b"garbage"), "7", GOLDEN_HEAD, Some("1"), &key()).unwrap();
    assert_eq!(
        base,
        FoldBase::Fresh {
            note: Some(
                "the receipt on disk is for #? at , not this head; starting a new one".into()
            )
        }
    );
}

#[test]
fn a_prior_receipt_at_this_head_with_a_bad_or_missing_signature_is_never_folded() {
    let good = build(fresh(), &part("rust", "1", 1), Some("1"));
    let mut tampered = parse(std::str::from_utf8(&good).unwrap());
    tampered.insert("proof".into(), Value::String("edited".into()));
    let mut unsigned = tampered.clone();
    unsigned.shift_remove("signature");
    let mut ran = 0;
    for (bytes, fault) in [
        (pyjson::dumps(&Value::Object(tampered)).into_bytes(), SigFault::Mismatch),
        (pyjson::dumps(&Value::Object(unsigned)).into_bytes(), SigFault::Unsigned),
    ] {
        let error = plan_fold(Some(&bytes), "7", GOLDEN_HEAD, Some("1"), &key()).unwrap_err();
        assert_eq!(error, ReceiptError::PriorNotTrusted { fault });
        ran += 1;
    }
    assert_eq!(ran, 2);
}

#[test]
fn a_trusted_prior_receipt_contributes_its_proofs() {
    let prior = build(fresh(), &part("rust", "12", 101), Some("1"));
    let base = plan_fold(Some(&prior), "7", GOLDEN_HEAD, Some("1"), &key()).unwrap();
    match base {
        FoldBase::Fold { proofs } => {
            assert_eq!(proofs.len(), 1);
            assert_eq!(proofs[0].suite, "rust");
            assert_eq!(proofs[0].units_run, "12");
        }
        other @ FoldBase::Fresh { .. } => panic!("expected a fold, got {other:?}"),
    }
}

#[test]
fn folding_a_second_suite_keeps_both_sorted_and_joins_the_flat_fields() {
    let first = build(fresh(), &part("rust", "12", 101), Some("1"));
    let second = fold_in(&first, &part("python", "3", 1));
    assert_eq!(field(&second, "suite"), Value::String("python rust".into()));
    assert_eq!(field(&second, "units_run"), Value::String("python:3, rust:12".into()));
    assert_eq!(field(&second, "partial"), Value::Bool(true));
    let proof = field(&second, "proof");
    assert!(proof.as_str().unwrap().contains(" AND "), "{proof}");
    assert!(
        proof
            .as_str()
            .unwrap()
            .starts_with("`python_filter` passes clean and fails under `s/python/x/` (rc=1) AND ")
    );
    let proofs = field(&second, "proofs");
    let names: Vec<&str> =
        proofs.as_array().unwrap().iter().map(|p| p["suite"].as_str().unwrap()).collect();
    assert_eq!(names, vec!["python", "rust"]);
    // The flat mutation, filter and failure are the newest part's.
    assert_eq!(field(&second, "mutation"), Value::String("s/python/x/".into()));
    assert_eq!(field(&second, "filter"), Value::String("python_filter".into()));
    assert_eq!(field(&second, "observed_failure"), Value::String("python failed".into()));
}

#[test]
fn folding_three_suites_drops_none() {
    let a = build(fresh(), &part("b", "1", 1), Some("1"));
    let b = fold_in(&a, &part("c", "2", 1));
    let c = fold_in(&b, &part("a", "3", 1));
    let names = Stored::parse(&c).unwrap().suites();
    assert_eq!(names, vec!["a", "b", "c"]);
    assert_eq!(field(&c, "units_run"), Value::String("a:3, b:1, c:2".into()));
}

#[test]
fn proving_a_suite_again_replaces_its_part_and_does_not_inflate_coverage() {
    let first = build(fresh(), &part("rust", "12", 101), Some("1"));
    let again = fold_in(&first, &part("rust", "15", 7));
    let proofs = field(&again, "proofs");
    assert_eq!(proofs.as_array().unwrap().len(), 1);
    assert_eq!(proofs[0]["units_run"], Value::String("15".into()));
    assert_eq!(field(&again, "units_run"), Value::String("15".into()));
    // Folded in, so still partial even with one proof left.
    assert_eq!(field(&again, "partial"), Value::Bool(true));
}

#[test]
fn partial_follows_the_fold_or_a_verify_part_of_exactly_one() {
    let p = part("rust", "1", 1);
    let cases = [(None, false), (Some("1"), true), (Some("0"), false), (Some("yes"), false)];
    let got: Vec<bool> = cases
        .iter()
        .map(|(vp, _)| field(&build(fresh(), &p, *vp), "partial").as_bool().unwrap())
        .collect();
    let want: Vec<bool> = cases.iter().map(|(_, w)| *w).collect();
    assert_eq!(got, want);
}

#[test]
fn a_single_proof_carries_its_units_run_unprefixed() {
    let bytes = build(fresh(), &part("rust", "12", 101), None);
    assert_eq!(field(&bytes, "units_run"), Value::String("12".into()));
    assert_eq!(field(&bytes, "suite"), Value::String("rust".into()));
    assert_eq!(
        field(&bytes, "proof"),
        Value::String("`rust_filter` passes clean and fails under `s/rust/x/` (rc=101)".into())
    );
}

#[test]
fn a_prior_receipt_with_only_a_flat_suite_folds_as_no_proofs() {
    // Pins current behaviour: the old flat `suite` is dropped, not carried over.
    let mut old = body(&[("suite", Value::String("old-suite".into()))]);
    old.insert("kind".into(), Value::String("observed".into()));
    let prior = signed(old);
    let base = plan_fold(Some(&prior), "7", GOLDEN_HEAD, Some("1"), &key()).unwrap();
    assert_eq!(base, FoldBase::Fold { proofs: Vec::new() });
    let bytes = build(base, &part("rust", "1", 1), Some("1"));
    assert_eq!(Stored::parse(&bytes).unwrap().suites(), vec!["rust"]);
}

#[test]
fn an_observed_receipt_writes_its_keys_in_the_order_the_gate_writes_them() {
    let bytes = build(fresh(), &part("rust", "1", 1), Some("1"));
    let keys: Vec<String> = parse(std::str::from_utf8(&bytes).unwrap()).keys().cloned().collect();
    assert_eq!(
        keys,
        [
            "pr",
            "head",
            "kind",
            "partial",
            "suite",
            "units_run",
            "proof",
            "mutation",
            "filter",
            "observed_failure",
            "proofs",
            "recorded_at",
            "recorded_by",
            "signature"
        ]
    );
}
