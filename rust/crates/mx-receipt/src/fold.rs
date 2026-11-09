//! Part mode: folding one more suite's proof into a receipt earned at the same head.

use crate::error::ReceiptError;
use crate::key::Key;
use crate::receipt::Stored;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// One suite's proof inside a receipt's `proofs` list.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Proof {
    pub suite: String,
    pub units_run: String,
    pub filter: String,
    pub mutation: String,
    pub proof: String,
    pub observed_failure: String,
}

/// What one `verify` run observed, ready to become a [`Proof`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Part {
    pub suite: String,
    /// The count of test units the clean run reported, as text.
    pub units_run: String,
    pub filter: String,
    pub mutation: String,
    /// The exit code of the mutated run.
    pub mutated_rc: i32,
    /// The first failure line of the mutated run's log.
    pub observed_failure: String,
}

/// Where a new receipt starts from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FoldBase {
    /// A new receipt. `note` is the line the gate prints when a receipt on disk
    /// belongs to another pull request or head (part mode only).
    Fresh { note: Option<String> },
    /// The proofs of the receipt already on disk at this head.
    Fold { proofs: Vec<Proof> },
}

/// Bash `cmd_verify` before it writes: decide whether to fold into the receipt
/// on disk.
///
/// - `verify_part` is the `VERIFY_PART` variable. Unset or empty means a plain
///   `verify`: the file is replaced and never read.
/// - In part mode with no file, the receipt is new.
/// - A file for another pull request or head (compared as text with `pr_arg`
///   and `real_head`; an unreadable file reads as no pr and no head) starts a
///   new receipt with a note.
/// - A file for this pull request and head must carry a signature that checks
///   out, or nothing is folded: a hand-written receipt naming suites nobody ran
///   would otherwise be picked up and re-sealed with a real signature.
///
/// The prior receipt's proofs fold in only after that check. A prior receipt
/// with no `proofs` list folds as no proofs.
pub fn plan_fold(
    prior: Option<&[u8]>,
    pr_arg: &str,
    real_head: &str,
    verify_part: Option<&str>,
    key: &Key,
) -> Result<FoldBase, ReceiptError> {
    let part_mode = verify_part.is_some_and(|v| !v.is_empty());
    let Some(bytes) = prior.filter(|_| part_mode) else {
        return Ok(FoldBase::Fresh { note: None });
    };
    let (prior_pr, prior_head, stored) = match Stored::parse(bytes) {
        Ok(stored) => (stored.field_text("pr", ""), stored.field_text("head", ""), Some(stored)),
        Err(_) => (String::new(), String::new(), None),
    };
    let Some(stored) = stored.filter(|_| prior_pr == pr_arg && prior_head == real_head) else {
        let shown_pr = if prior_pr.is_empty() { "?" } else { prior_pr.as_str() };
        let short: String = prior_head.chars().take(8).collect();
        return Ok(FoldBase::Fresh {
            note: Some(format!(
                "the receipt on disk is for #{shown_pr} at {short}, not this head; starting a new one"
            )),
        });
    };
    stored.verify_signature(key).map_err(|fault| ReceiptError::PriorNotTrusted { fault })?;
    let proofs = match stored.proofs_value() {
        Some(Value::Array(items)) => items
            .iter()
            .map(|item| {
                serde_json::from_value::<Proof>(item.clone()).map_err(|error| ReceiptError::Shape {
                    reason: format!("a prior proof: {error}"),
                })
            })
            .collect::<Result<Vec<_>, _>>()?,
        _ => Vec::new(),
    };
    Ok(FoldBase::Fold { proofs })
}
