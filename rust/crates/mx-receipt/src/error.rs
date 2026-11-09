//! What can go wrong with a receipt, and the `Refusal` each failure becomes.

use mx_core::Refusal;
use thiserror::Error;

/// Why a receipt's signature did not check out. The numbers are the codes the
/// bash `receipt_signature_ok` returns, and `merge` and `verify-part` name them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SigFault {
    /// Code 1: the file is not readable JSON, or its top level is not an object.
    NotJson,
    /// Code 2: there is no `signature` field, or it is the empty string.
    Unsigned,
    /// Code 3: a signature is present and is not the HMAC of the rest.
    Mismatch,
}

impl SigFault {
    /// The bash return code.
    #[must_use]
    pub fn code(self) -> u8 {
        match self {
            Self::NotJson => 1,
            Self::Unsigned => 2,
            Self::Mismatch => 3,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum ReceiptError {
    /// The key file is not UTF-8 text.
    #[error("the receipt key is not UTF-8 text")]
    KeyNotText,
    /// No key file at the path.
    #[error("no receipt key at {path}; run ./install.sh")]
    KeyMissing { path: String },
    /// The bytes are not a JSON object.
    #[error("the receipt is not readable JSON: {reason}")]
    NotJson { reason: String },
    /// The receipt has a field the model does not know, or lacks one it needs.
    #[error("the receipt has the wrong shape: {reason}")]
    Shape { reason: String },
    /// There is no signature.
    #[error("the receipt carries no signature, so it was not written by `maintainer-merge verify`")]
    Unsigned,
    /// The signature does not match the body.
    #[error(
        "the receipt does not match its signature: it was edited after it was written, or written by something other than the gate"
    )]
    SignatureMismatch,
    /// The receipt names another pull request than the one asked for.
    #[error("the receipt was earned for #{found}, not #{wanted}")]
    WrongPullRequest { wanted: String, found: String },
    /// An unattended run may spend only `observed` and `dependency` receipts.
    #[error(
        "the receipt is '{kind}', not 'observed'; an unattended run merges only on an observed or dependency receipt"
    )]
    KindNotSpendable { kind: String },
    /// A hand-recorded head is shorter than seven characters.
    #[error("head sha looks truncated: {head}")]
    HeadTruncated { head: String },
    /// An unattended run asked to assert a receipt.
    #[error("an unattended run may not assert a receipt")]
    UnattendedAssert,
    /// A prior receipt at this head failed its signature check, so no proof is folded into it.
    #[error("a receipt already exists at this head and its signature does not check out (code {code}); refusing to fold a new proof into it and re-seal it", code = .fault.code())]
    PriorNotTrusted { fault: SigFault },
    /// The pull request argument is not a string of digits.
    #[error("pull request must be a positive integer, not '{given}'")]
    InvalidPrNumber { given: String },
    /// No receipt file for the pull request.
    #[error("no receipt for #{pr}")]
    NoReceipt { pr: String },
    /// The store could not read or write.
    #[error("receipt store: {reason}")]
    Store { reason: String },
}

impl ReceiptError {
    /// The refusal the gate reports for this error. Every receipt refusal in
    /// bash is a `die`, exit 1; the message text differs from the bash text and
    /// the exit code does not.
    #[must_use]
    pub fn into_refusal(self, pr: u64) -> Refusal {
        match self {
            Self::KeyNotText => {
                Refusal::Unreadable { what: "the receipt key".into(), reason: self.to_string() }
            }
            Self::KeyMissing { path } => {
                Refusal::Missing { what: format!("the receipt key at {path}") }
            }
            Self::UnattendedAssert => {
                Refusal::NotForUnattendedRun { action: "assert a receipt".into() }
            }
            Self::InvalidPrNumber { given } => Refusal::InvalidPrNumber { given },
            Self::NoReceipt { .. } => Refusal::ReceiptMissing { pr },
            Self::Store { reason } => {
                Refusal::Unreadable { what: "the receipt store".into(), reason }
            }
            Self::NotJson { .. }
            | Self::Shape { .. }
            | Self::Unsigned
            | Self::SignatureMismatch
            | Self::WrongPullRequest { .. }
            | Self::KindNotSpendable { .. }
            | Self::HeadTruncated { .. }
            | Self::PriorNotTrusted { .. } => {
                Refusal::ReceiptInvalid { pr, reason: self.to_string() }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_receipt_error_maps_to_a_refusal_with_exit_code_1() {
        let errors = [
            ReceiptError::KeyNotText,
            ReceiptError::KeyMissing { path: "/k".into() },
            ReceiptError::NotJson { reason: "x".into() },
            ReceiptError::Shape { reason: "x".into() },
            ReceiptError::Unsigned,
            ReceiptError::SignatureMismatch,
            ReceiptError::WrongPullRequest { wanted: "7".into(), found: "8".into() },
            ReceiptError::KindNotSpendable { kind: "asserted".into() },
            ReceiptError::HeadTruncated { head: "abc".into() },
            ReceiptError::UnattendedAssert,
            ReceiptError::PriorNotTrusted { fault: SigFault::Mismatch },
            ReceiptError::InvalidPrNumber { given: "../x".into() },
            ReceiptError::NoReceipt { pr: "7".into() },
            ReceiptError::Store { reason: "x".into() },
        ];
        assert_eq!(errors.len(), 14);
        for error in errors {
            let shown = format!("{error:?}");
            assert_eq!(error.into_refusal(7).exit_code(), 1, "{shown}");
        }
    }

    #[test]
    fn signature_fault_codes_are_the_bash_return_codes() {
        assert_eq!(SigFault::NotJson.code(), 1);
        assert_eq!(SigFault::Unsigned.code(), 2);
        assert_eq!(SigFault::Mismatch.code(), 3);
    }
}
