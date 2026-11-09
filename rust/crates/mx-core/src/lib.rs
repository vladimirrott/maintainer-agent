//! Typed foundations for the magent Rust programs.
//!
//! Three types carry the fail-closed discipline:
//!
//! - [`Fact`] is the result of reading the outside world. It has three states,
//!   and [`Fact::Unreadable`] never turns into [`Fact::Absent`].
//! - [`Refusal`] names every way a program declines to go on. Its
//!   [`Refusal::exit_code`] is an exhaustive `match` with no catch-all arm, so
//!   the compiler demands an exit code for each new variant.
//! - [`NonEmpty`] is a list that cannot be empty, so "the list came back empty"
//!   is a parse failure at the boundary and not a case deep inside a decision.
//!
//! This crate performs no I/O and reads no environment.

mod fact;
mod nonempty;
mod refusal;

pub use fact::Fact;
pub use nonempty::{Empty, NonEmpty};
pub use refusal::{EXIT_CONFIG, EXIT_FAIL, EXIT_OK, EXIT_TEMPFAIL, EXIT_USAGE, Refusal};
