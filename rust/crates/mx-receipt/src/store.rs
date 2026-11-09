//! Where receipts live: `<state>/receipts/<pr>.json`, read and written through an [`Fs`].

use crate::error::ReceiptError;
use crate::receipt::{Receipt, Signed};
use mx_core::Fact;
use mx_ports::Fs;
use std::path::{Path, PathBuf};

/// `<dir>/<pr_arg>.json`. The argument is used as text, so `007` names
/// `007.json`, as in bash; the caller has checked it is digits.
#[must_use]
pub fn receipt_path(dir: &Path, pr_arg: &str) -> PathBuf {
    dir.join(format!("{pr_arg}.json"))
}

/// A pull request argument is one or more ASCII digits.
///
/// The bash `show` skips this check and `cat`s `$RECEIPTS/$1.json`, so
/// `show ../x` reads outside the receipt directory. Plan decision F2: the Rust
/// port refuses it. The other subcommands already used `pr_or_die`.
pub fn pr_arg_or_refuse(arg: &str) -> Result<&str, ReceiptError> {
    if arg.is_empty() || !arg.bytes().all(|b| b.is_ascii_digit()) {
        return Err(ReceiptError::InvalidPrNumber { given: arg.to_string() });
    }
    Ok(arg)
}

/// Reads a receipt file: absent is `Absent`, an unreadable file is `Unreadable`.
pub fn read(fs: &dyn Fs, path: &Path) -> Fact<Vec<u8>> {
    fs.read(path)
}

/// Writes a signed receipt, replacing a file of the same name without a word
/// (pins current behaviour). Only a `Receipt<Signed>` has bytes to write.
/// The caller has created the directory.
pub fn write(fs: &dyn Fs, path: &Path, receipt: &Receipt<Signed>) -> Result<(), ReceiptError> {
    fs.write(path, &receipt.to_bytes())
        .map_err(|error| ReceiptError::Store { reason: error.to_string() })
}
