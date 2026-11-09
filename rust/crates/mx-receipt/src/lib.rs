//! Receipts the merge gate writes, signs, reads and folds.
//!
//! The bash gate (`bin/maintainer-merge`) records what it proved about a pull
//! request in `<state>/receipts/<pr>.json`, signed with an HMAC-SHA256 over the
//! body as Python `json.dump(indent=2)` writes it. This crate reads and writes
//! the same bytes, so a receipt written by either program verifies under the
//! other (`tests/interop.sh` runs both directions against the real gate).
//!
//! - [`pyjson`]: the Python-compatible JSON writer.
//! - [`Key`]: the signing key and the HMAC.
//! - [`Receipt`]: `Unsigned` and `Signed` states, the three writers
//!   ([`Receipt::asserted`], [`Receipt::dependency`], [`Receipt::observed`]).
//! - [`Stored`]: a file's contents; [`Stored::check`] is the gate's
//!   `receipt_check`.
//! - [`plan_fold`]: part mode, folding a suite's proof into a prior receipt.
//! - [`show_one`] and [`show_list`]: `show`.
//!
//! What stays outside: `receipt_covers` and `receipt_fresh` ask `gh` and `git`
//! questions, so they belong to the gate crate. This crate gives them
//! [`Receipt::suites`], [`Receipt::is_partial`] and [`Receipt::head`].
//!
//! No terminal output, no environment reads, no process. Files go through
//! `mx_ports::Fs`.

mod error;
mod fold;
mod key;
pub mod pyjson;
mod receipt;
mod show;
mod stamp;
mod store;

pub use error::{ReceiptError, SigFault};
pub use fold::{FoldBase, Part, Proof, plan_fold};
pub use key::Key;
pub use receipt::{Body, DependencyFacts, Kind, Receipt, Signed, Stored, Unsigned};
pub use show::{ListEntry, show_list, show_one};
pub use stamp::{Stamp, iso_with_offset};
pub use store::{pr_arg_or_refuse, read, receipt_path, write};
