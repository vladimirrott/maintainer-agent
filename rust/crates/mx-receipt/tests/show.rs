//! `show`, the store and the typestate boundary.
use mx_core::Fact;
use mx_ports::{EffectLog, FakeFs, Fs};
use mx_receipt::{
    ListEntry, Receipt, ReceiptError, Stamp, receipt_path, show_list, show_one, write,
};
use std::path::Path;

mod common;
use common::*;

const DIR: &str = "/state/receipts";

fn fs() -> (FakeFs, EffectLog) {
    let log = EffectLog::new();
    (FakeFs::new(&log), log)
}

fn receipt_json(head: &str, proof: &str) -> String {
    format!("{{\"pr\": 1, \"head\": {head:?}, \"proof\": {proof:?}}}")
}

fn lines(fs: &FakeFs) -> Vec<String> {
    show_list(fs, Path::new(DIR))
        .unwrap()
        .into_iter()
        .map(|entry| match entry {
            ListEntry::Line(line) => line,
            other @ ListEntry::Unreadable { .. } => panic!("unexpected {other:?}"),
        })
        .collect()
}

#[test]
fn the_listing_has_one_line_per_receipt_in_file_name_order() {
    let (fs, _) = fs();
    fs.put("/state/receipts/9.json", receipt_json("cc5e01302bbd", "nine"), 0);
    fs.put("/state/receipts/10.json", receipt_json("abcdef0123", "ten"), 0);
    assert_eq!(lines(&fs), vec!["  10: abcdef01 ten", "  9: cc5e0130 nine"]);
}

#[test]
fn the_head_is_cut_to_eight_characters_and_the_proof_to_sixty() {
    let (fs, _) = fs();
    let proof = format!("{}{}", "p".repeat(59), "\u{e9}tail");
    fs.put("/state/receipts/1.json", receipt_json("\u{e9}bcdefghij", &proof), 0);
    let line = lines(&fs).remove(0);
    assert_eq!(line, format!("  1: \u{e9}bcdefgh {}\u{e9}", "p".repeat(59)));
}

#[test]
fn newlines_that_end_the_cut_proof_are_stripped_like_command_substitution() {
    let (fs, _) = fs();
    fs.put("/state/receipts/1.json", receipt_json("abcdefgh", "ends here\n\n"), 0);
    assert_eq!(lines(&fs), vec!["  1: abcdefgh ends here"]);
}

#[test]
fn files_that_are_not_json_receipts_are_skipped_by_name_or_reported() {
    let (fs, _) = fs();
    fs.put("/state/receipts/1.json", receipt_json("abcdefgh", "ok"), 0);
    fs.put("/state/receipts/notes.txt", "x", 0);
    fs.put("/state/receipts/2.json", "not json", 0);
    let entries = show_list(&fs, Path::new(DIR)).unwrap();
    assert_eq!(entries.len(), 2);
    assert_eq!(entries[0], ListEntry::Line("  1: abcdefgh ok".into()));
    assert!(matches!(&entries[1], ListEntry::Unreadable { file, .. } if file == "2.json"));
}

#[test]
fn an_empty_or_missing_directory_lists_nothing() {
    let (fs, _) = fs();
    assert!(show_list(&fs, Path::new(DIR)).unwrap().is_empty());
}

#[test]
fn an_unreadable_directory_is_an_error_and_not_an_empty_listing() {
    let (fs, _) = fs();
    fs.make_unreadable(DIR, "permission denied");
    assert_eq!(
        show_list(&fs, Path::new(DIR)).unwrap_err(),
        ReceiptError::Store { reason: "permission denied".into() }
    );
}

#[test]
fn show_one_returns_the_file_bytes_unchanged() {
    let (fs, _) = fs();
    fs.put("/state/receipts/7.json", golden_receipt(), 0);
    assert_eq!(show_one(&fs, Path::new(DIR), "7").unwrap(), golden_receipt().as_bytes());
}

#[test]
fn show_one_reports_a_missing_receipt() {
    let (fs, _) = fs();
    assert_eq!(
        show_one(&fs, Path::new(DIR), "7").unwrap_err(),
        ReceiptError::NoReceipt { pr: "7".into() }
    );
}

#[test]
fn show_one_refuses_an_argument_that_is_not_digits_and_never_reads() {
    // Plan decision F2: bash would cat /state/receipts/../secret.json.
    let (fs, log) = fs();
    fs.put("/state/secret.json", "TOP SECRET", 0);
    let mut ran = 0;
    for arg in ["../secret", "7/../../secret", "", "7 ", "-1", "7.json", "\u{661}"] {
        let error = show_one(&fs, Path::new(DIR), arg).unwrap_err();
        assert_eq!(error, ReceiptError::InvalidPrNumber { given: arg.into() }, "{arg:?}");
        ran += 1;
    }
    assert_eq!(ran, 7);
    assert!(log.entries().is_empty(), "a refused argument must not touch the filesystem");
}

#[test]
fn show_one_reports_an_unreadable_receipt_as_a_store_error() {
    let (fs, _) = fs();
    fs.put("/state/receipts/7.json", "x", 0);
    fs.make_unreadable("/state/receipts/7.json", "permission denied");
    assert_eq!(
        show_one(&fs, Path::new(DIR), "7").unwrap_err(),
        ReceiptError::Store { reason: "permission denied".into() }
    );
}

#[test]
fn the_receipt_path_uses_the_argument_as_text() {
    assert_eq!(receipt_path(Path::new(DIR), "007"), Path::new("/state/receipts/007.json"));
}

#[test]
fn a_signed_receipt_is_written_to_its_path_and_reads_back_to_the_same_bytes() {
    let (fs, _) = fs();
    let stamp = Stamp::new("2026-01-01T00:00:00+00:00", "fixture-user");
    let receipt = Receipt::asserted(7, GOLDEN_HEAD, "proof", &stamp, false).unwrap().sign(&key());
    let path = receipt_path(Path::new(DIR), "7");
    write(&fs, &path, &receipt).unwrap();
    assert_eq!(fs.read(&path), Fact::Known(receipt.to_bytes()));
    // A second receipt for the same pull request replaces the first.
    let second = Receipt::asserted(7, GOLDEN_HEAD, "second", &stamp, false).unwrap().sign(&key());
    write(&fs, &path, &second).unwrap();
    assert_eq!(fs.read(&path), Fact::Known(second.to_bytes()));
}

#[test]
fn a_failed_write_is_an_error() {
    let (fs, _) = fs();
    fs.fail_writes_to("/state/receipts/7.json", "disk full");
    let stamp = Stamp::new("t", "u");
    let receipt = Receipt::asserted(7, GOLDEN_HEAD, "p", &stamp, false).unwrap().sign(&key());
    let error = write(&fs, Path::new("/state/receipts/7.json"), &receipt).unwrap_err();
    assert!(matches!(error, ReceiptError::Store { .. }));
}
