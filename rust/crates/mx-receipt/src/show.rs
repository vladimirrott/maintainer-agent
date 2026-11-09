//! `maintainer-merge show`: one receipt's bytes, or one line per receipt.

use crate::error::ReceiptError;
use crate::store::{pr_arg_or_refuse, receipt_path};
use mx_core::Fact;
use mx_ports::Fs;
use serde_json::Value;
use std::path::Path;

/// `show <pr>`: the receipt file's bytes, as `cat` prints them.
///
/// The argument must be digits (plan decision F2; bash accepts any text and
/// reads outside the directory). A missing file and an unreadable file are both
/// "no receipt", as in bash, and both refuse.
pub fn show_one(fs: &dyn Fs, dir: &Path, pr_arg: &str) -> Result<Vec<u8>, ReceiptError> {
    let pr = pr_arg_or_refuse(pr_arg)?;
    match fs.read(&receipt_path(dir, pr)) {
        Fact::Known(bytes) => Ok(bytes),
        Fact::Absent => Err(ReceiptError::NoReceipt { pr: pr.to_string() }),
        Fact::Unreadable(reason) => Err(ReceiptError::Store { reason }),
    }
}

/// One entry of the listing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ListEntry {
    /// `  <pr>: <first 8 characters of head> <first 60 characters of proof>`.
    Line(String),
    /// A file bash would have shown a Python traceback for and no line.
    Unreadable { file: String, reason: String },
}

/// `show` with no argument: every `*.json` in the directory, in byte order of
/// the file name (bash sorts by the shell's collation; digits sort the same).
/// An empty directory is an empty list and the caller prints
/// `no receipts recorded`.
///
/// Python's `print` ends the text with a newline that `$(...)` strips together
/// with any newlines the proof slice ends in; the line here is trimmed the
/// same way.
pub fn show_list(fs: &dyn Fs, dir: &Path) -> Result<Vec<ListEntry>, ReceiptError> {
    let files = match fs.list(dir) {
        Fact::Known(files) => files,
        Fact::Absent => return Ok(Vec::new()),
        Fact::Unreadable(reason) => return Err(ReceiptError::Store { reason }),
    };
    let mut entries = Vec::new();
    for file in files {
        let name = file.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let Some(stem) = name.strip_suffix(".json") else { continue };
        let bytes = match fs.read(&file) {
            Fact::Known(bytes) => bytes,
            Fact::Absent => continue,
            Fact::Unreadable(reason) => {
                entries.push(ListEntry::Unreadable { file: name, reason });
                continue;
            }
        };
        let described = match serde_json::from_slice::<Value>(&bytes) {
            Ok(value) => match (
                value.get("head").and_then(Value::as_str),
                value.get("proof").and_then(Value::as_str),
            ) {
                (Some(head), Some(proof)) => Ok((
                    head.chars().take(8).collect::<String>(),
                    proof.chars().take(60).collect::<String>(),
                )),
                _ => Err("head or proof is missing or not text".to_string()),
            },
            Err(error) => Err(error.to_string()),
        };
        match described {
            Ok((head, proof)) => {
                let text = format!("{stem}: {head} {proof}");
                entries.push(ListEntry::Line(format!("  {}", text.trim_end_matches('\n'))));
            }
            Err(reason) => entries.push(ListEntry::Unreadable { file: name, reason }),
        }
    }
    Ok(entries)
}
