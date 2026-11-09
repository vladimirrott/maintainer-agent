//! The receipt model: build, sign, read, verify.
//!
//! # Typestate
//!
//! `Receipt<Unsigned>` is a body that has no signature. It has no way to
//! become bytes, so no code path can write one. `Receipt<Signed>` holds a
//! signature that this program computed (`sign`) or checked (`Stored::check`).
//!
//! # Quirks of the bash gate that this model keeps (plan decision: PRESERVE)
//!
//! - The signature covers the receipt **parsed and written again** with
//!   `json.dump(indent=2)`, not the file's own bytes. Whitespace, a trailing
//!   newline and `é` against a raw `é` do not change the verdict. Key
//!   **order** does: a receipt whose keys were reordered fails.
//! - The `pr` and `kind` checks compare what Python's `print` shows for the
//!   field, so a receipt for pull request `7` is refused when the command line
//!   said `007`, and a bash `merge` passes a signed receipt whose `pr` is the
//!   string `"7"`. The Rust check keeps the string comparison and refuses the
//!   typed model afterwards (`deny_unknown_fields` and `pr: u64`), which is
//!   stricter than bash for a receipt only a holder of the key can write.
//! - A `kind` that is none of `observed`, `dependency`, `asserted` is still
//!   spendable outside an unattended run, with the asserted notice.
//! - A key file with a missing key, an unreadable file or non-UTF-8 text stops
//!   the signing. Bash left an unsigned receipt on disk when the key was
//!   missing (the characterization case pins that). The Rust writer cannot:
//!   an unsigned receipt has no bytes to write. A deviation toward fail-closed,
//!   recorded in the PR; `merge` refused that file as unsigned anyway.

use crate::error::{ReceiptError, SigFault};
use crate::fold::{FoldBase, Part, Proof};
use crate::key::Key;
use crate::pyjson;
use crate::stamp::Stamp;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::marker::PhantomData;

/// What a receipt vouches for.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(from = "String", into = "String")]
pub enum Kind {
    /// `verify` watched the mutation fail.
    Observed,
    /// `verify-deps` checked a pure dependency bump.
    Dependency,
    /// A human recorded a claim; nothing checked it.
    Asserted,
    /// Any other text. Bash spends it like `asserted`.
    Other(String),
}

impl From<String> for Kind {
    fn from(text: String) -> Self {
        match text.as_str() {
            "observed" => Self::Observed,
            "dependency" => Self::Dependency,
            "asserted" => Self::Asserted,
            _ => Self::Other(text),
        }
    }
}

impl From<Kind> for String {
    fn from(kind: Kind) -> Self {
        match kind {
            Kind::Observed => "observed".into(),
            Kind::Dependency => "dependency".into(),
            Kind::Asserted => "asserted".into(),
            Kind::Other(text) => text,
        }
    }
}

/// Every field any writer produces, in the order the writers produce them.
/// `Serialize` follows the field order, which is the key order of the file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Body {
    pub pr: u64,
    pub head: String,
    pub kind: Kind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub partial: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub suite: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub units_run: Option<String>,
    pub proof: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mutation: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub filter: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub observed_failure: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub proofs: Option<Vec<Proof>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub files: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub changed_lines: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pins_verified: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub images_verified: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pip_verified: Option<u64>,
    pub recorded_at: String,
    pub recorded_by: String,
}

/// Marker: no signature.
#[derive(Debug, Clone, Copy)]
pub struct Unsigned;
/// Marker: carries a signature this program computed or checked.
#[derive(Debug, Clone, Copy)]
pub struct Signed;

/// A receipt in state `S`.
#[derive(Debug, Clone)]
pub struct Receipt<S> {
    /// The fields in file order. For a parsed receipt this is the file's order.
    map: Map<String, Value>,
    body: Body,
    state: PhantomData<S>,
}

fn body_map(body: &Body) -> Map<String, Value> {
    match serde_json::to_value(body) {
        Ok(Value::Object(map)) => map,
        // A struct of strings, numbers and booleans always serialises to an object.
        _ => unreachable!("Body serialises to a JSON object"),
    }
}

impl<S> Receipt<S> {
    /// The typed fields.
    #[must_use]
    pub fn body(&self) -> &Body {
        &self.body
    }
}

impl Receipt<Unsigned> {
    fn new(body: Body) -> Self {
        Self { map: body_map(&body), body, state: PhantomData }
    }

    /// A receipt a human records with `maintainer-merge receipt`.
    ///
    /// Bash order of refusals: an unattended run first, then a head shorter
    /// than seven characters (`${#sha}`, counted in characters). Any head of
    /// seven or more characters is recorded as typed (pins current behaviour).
    pub fn asserted(
        pr: u64,
        head: &str,
        proof: &str,
        stamp: &Stamp,
        unattended: bool,
    ) -> Result<Self, ReceiptError> {
        if unattended {
            return Err(ReceiptError::UnattendedAssert);
        }
        if head.chars().count() < 7 {
            return Err(ReceiptError::HeadTruncated { head: head.to_string() });
        }
        Ok(Self::new(Body {
            pr,
            head: head.to_string(),
            kind: Kind::Asserted,
            partial: None,
            suite: None,
            units_run: None,
            proof: proof.to_string(),
            mutation: None,
            filter: None,
            observed_failure: None,
            proofs: None,
            files: None,
            changed_lines: None,
            pins_verified: None,
            images_verified: None,
            pip_verified: None,
            recorded_at: stamp.recorded_at.clone(),
            recorded_by: stamp.recorded_by.clone(),
        }))
    }

    /// The receipt `verify-deps` writes for a pure dependency bump.
    #[must_use]
    pub fn dependency(pr: u64, head: &str, facts: &DependencyFacts, stamp: &Stamp) -> Self {
        let proof = format!(
            "pure dependency bump: {lines} changed line(s) in {files}; no source outside crates.io/registry.npmjs.org/PyPI, no new install script, {pins} action pin(s) verified against their tags, {images} base image(s) verified against their registry, {pips} pip package(s) verified against PyPI",
            lines = facts.changed_lines,
            files = facts.files,
            pins = facts.pins_verified,
            images = facts.images_verified,
            pips = facts.pip_verified,
        );
        Self::new(Body {
            pr,
            head: head.to_string(),
            kind: Kind::Dependency,
            partial: None,
            suite: None,
            units_run: None,
            proof,
            mutation: None,
            filter: None,
            observed_failure: None,
            proofs: None,
            files: Some(facts.files.clone()),
            changed_lines: Some(facts.changed_lines),
            pins_verified: Some(facts.pins_verified),
            images_verified: Some(facts.images_verified),
            pip_verified: Some(facts.pip_verified),
            recorded_at: stamp.recorded_at.clone(),
            recorded_by: stamp.recorded_by.clone(),
        })
    }

    /// The receipt `verify` and `verify-part` write after a clean pass and a
    /// failing mutated run. `base` says whether a prior receipt's proofs are
    /// folded in (see [`crate::plan_fold`]); `verify_part` is the value of the
    /// `VERIFY_PART` variable (`Some("1")` for `verify-part`).
    ///
    /// The part replaces any proof of the same suite, the proofs sort by suite
    /// name, and the flat fields describe the whole: one proof carries exactly
    /// what it always did, several join (`suite` with a space, `proof` with
    /// ` AND `, `units_run` as `suite:units` joined by `, `). The flat
    /// `mutation`, `filter` and `observed_failure` are the newest part's.
    /// `partial` is true when proofs were folded or `verify_part` is `"1"`.
    ///
    /// A prior receipt with a single flat `suite` and no `proofs` folds as an
    /// empty list: its suite is dropped (pins current behaviour).
    #[must_use]
    pub fn observed(
        pr: u64,
        head: &str,
        base: FoldBase,
        part: &Part,
        verify_part: Option<&str>,
        stamp: &Stamp,
    ) -> Self {
        let folded = matches!(base, FoldBase::Fold { .. });
        let mut proofs = match base {
            FoldBase::Fold { proofs } => proofs,
            FoldBase::Fresh { .. } => Vec::new(),
        };
        proofs.retain(|p| p.suite != part.suite);
        proofs.push(Proof {
            suite: part.suite.clone(),
            units_run: part.units_run.clone(),
            filter: part.filter.clone(),
            mutation: part.mutation.clone(),
            proof: format!(
                "`{}` passes clean and fails under `{}` (rc={})",
                part.filter, part.mutation, part.mutated_rc
            ),
            observed_failure: part.observed_failure.clone(),
        });
        proofs.sort_by(|a, b| a.suite.cmp(&b.suite));
        let units_run = if proofs.len() == 1 {
            proofs[0].units_run.clone()
        } else {
            proofs
                .iter()
                .map(|p| format!("{}:{}", p.suite, p.units_run))
                .collect::<Vec<_>>()
                .join(", ")
        };
        Self::new(Body {
            pr,
            head: head.to_string(),
            kind: Kind::Observed,
            partial: Some(folded || verify_part == Some("1")),
            suite: Some(proofs.iter().map(|p| p.suite.as_str()).collect::<Vec<_>>().join(" ")),
            units_run: Some(units_run),
            proof: proofs.iter().map(|p| p.proof.as_str()).collect::<Vec<_>>().join(" AND "),
            mutation: Some(part.mutation.clone()),
            filter: Some(part.filter.clone()),
            observed_failure: Some(part.observed_failure.clone()),
            proofs: Some(proofs),
            files: None,
            changed_lines: None,
            pins_verified: None,
            images_verified: None,
            pip_verified: None,
            recorded_at: stamp.recorded_at.clone(),
            recorded_by: stamp.recorded_by.clone(),
        })
    }

    /// The bytes the signature covers: the body as `json.dump(indent=2)` writes it.
    pub(crate) fn payload(&self) -> String {
        pyjson::dumps(&Value::Object(self.map.clone()))
    }

    /// Signs the receipt. The signature goes last, as the bash `receipt_seal` appends it.
    #[must_use]
    pub fn sign(self, key: &Key) -> Receipt<Signed> {
        let signature = key.sign(self.payload().as_bytes());
        let mut map = self.map;
        map.insert("signature".to_string(), Value::String(signature));
        Receipt { map, body: self.body, state: PhantomData }
    }
}

impl Receipt<Signed> {
    /// The file's bytes: `json.dump(indent=2)`, no trailing newline.
    #[must_use]
    pub fn to_bytes(&self) -> Vec<u8> {
        pyjson::dumps(&Value::Object(self.map.clone())).into_bytes()
    }

    /// The signature, lower-case hex.
    #[must_use]
    pub fn signature(&self) -> &str {
        match self.map.get("signature") {
            Some(Value::String(text)) => text,
            _ => unreachable!("a signed receipt has a string signature"),
        }
    }

    /// `receipt_field head`, as text.
    #[must_use]
    pub fn head(&self) -> &str {
        &self.body.head
    }

    /// The message `merge` prints about the receipt's kind, without the two
    /// spaces `say` puts in front. `observed` has none.
    #[must_use]
    pub fn kind_notice(&self) -> Option<&'static str> {
        match self.body.kind {
            Kind::Observed => None,
            Kind::Dependency => Some(
                "the receipt is a DEPENDENCY receipt: nothing but dependency metadata\n     changed, and every action pin was checked against its tag",
            ),
            Kind::Asserted | Kind::Other(_) => Some(
                "the receipt is ASSERTED, not observed: it records a claim a\n     human made, and nothing here checked it",
            ),
        }
    }

    /// Bash `receipt_field partial false`: true only for JSON `true` (Python
    /// prints `True`) or the string `"true"`/`"True"`.
    #[must_use]
    pub fn is_partial(&self) -> bool {
        matches!(py_print(self.map.get("partial")).as_str(), "True" | "true")
    }

    /// Bash `receipt_suites`: the suite names the receipt was earned by, in
    /// order, without repeats. With `proofs` it reads each proof's `suite`;
    /// otherwise the flat `suite`. Empty names are dropped.
    #[must_use]
    pub fn suites(&self) -> Vec<String> {
        suites_of(&self.map)
    }
}

/// Facts `verify-deps` records.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DependencyFacts {
    pub files: String,
    pub changed_lines: u64,
    pub pins_verified: u64,
    pub images_verified: u64,
    pub pip_verified: u64,
}

/// A receipt file's contents, parsed and not yet checked.
#[derive(Debug, Clone)]
pub struct Stored {
    map: Map<String, Value>,
}

impl Stored {
    /// Reads the bytes as JSON. Not an object, not UTF-8, or not JSON is code 1.
    pub fn parse(bytes: &[u8]) -> Result<Self, ReceiptError> {
        match serde_json::from_slice::<Value>(bytes) {
            Ok(Value::Object(map)) => Ok(Self { map }),
            Ok(_) => Err(ReceiptError::NotJson { reason: "the top level is not an object".into() }),
            Err(error) => Err(ReceiptError::NotJson { reason: error.to_string() }),
        }
    }

    /// Bash `receipt_field`: what Python prints for the field, or `default`.
    #[must_use]
    pub fn field_text(&self, name: &str, default: &str) -> String {
        match self.map.get(name) {
            Some(value) => py_print(Some(value)),
            None => default.to_string(),
        }
    }

    /// Bash `receipt_signature_ok`.
    ///
    /// The signature is the HMAC of the body re-written with `json.dump(indent=2)`
    /// after the `signature` field is removed in place (the other keys keep
    /// their order). No signature field, or an empty one, is `Unsigned`; any
    /// other value that is not the right HMAC is `Mismatch`.
    pub fn verify_signature(&self, key: &Key) -> Result<(), SigFault> {
        let signature = match self.map.get("signature") {
            None => return Err(SigFault::Unsigned),
            Some(Value::String(text)) if text.is_empty() => return Err(SigFault::Unsigned),
            Some(Value::String(text)) => text.as_str(),
            // Python prints a non-string as a non-empty text, which never equals a digest.
            Some(_) => return Err(SigFault::Mismatch),
        };
        let mut rest = self.map.clone();
        rest.shift_remove("signature");
        let payload = pyjson::dumps(&Value::Object(rest));
        if key.verify(payload.as_bytes(), signature) { Ok(()) } else { Err(SigFault::Mismatch) }
    }

    /// Bash `receipt_check`: is this a signed receipt, earned for `pr_arg`, of
    /// a kind this caller may spend? `pr_arg` is the command-line text, compared
    /// as text. Checks run in the bash order: signature, pull request, kind,
    /// then the typed shape.
    pub fn check(
        self,
        key: &Key,
        pr_arg: &str,
        unattended: bool,
    ) -> Result<Receipt<Signed>, ReceiptError> {
        self.verify_signature(key).map_err(|fault| match fault {
            SigFault::NotJson => ReceiptError::NotJson { reason: "unreadable".into() },
            SigFault::Unsigned => ReceiptError::Unsigned,
            SigFault::Mismatch => ReceiptError::SignatureMismatch,
        })?;
        let found = py_print(self.map.get("pr"));
        if found != pr_arg {
            let found = if found.is_empty() { "<none>".to_string() } else { found };
            return Err(ReceiptError::WrongPullRequest { wanted: pr_arg.to_string(), found });
        }
        let kind = py_print(self.map.get("kind"));
        if unattended && kind != "observed" && kind != "dependency" {
            return Err(ReceiptError::KindNotSpendable { kind });
        }
        let mut rest = self.map.clone();
        rest.shift_remove("signature");
        let body: Body = serde_json::from_value(Value::Object(rest))
            .map_err(|error| ReceiptError::Shape { reason: error.to_string() })?;
        Ok(Receipt { map: self.map, body, state: PhantomData })
    }
}

/// What Python's `print` shows for a JSON value read with `json.load`, with the
/// field missing shown as an empty string.
pub(crate) fn py_print(value: Option<&Value>) -> String {
    match value {
        None => String::new(),
        Some(Value::Null) => "None".to_string(),
        Some(Value::Bool(true)) => "True".to_string(),
        Some(Value::Bool(false)) => "False".to_string(),
        Some(Value::Number(number)) => pyjson::number_text(&number.to_string()),
        Some(Value::String(text)) => text.clone(),
        Some(container) => container.to_string(),
    }
}

/// Suite names of a receipt body, as bash `receipt_suites` reads them.
pub(crate) fn suites_of(map: &Map<String, Value>) -> Vec<String> {
    let from_proofs: Vec<&str> = match map.get("proofs") {
        Some(Value::Array(items)) => {
            items.iter().map(|p| p.get("suite").and_then(Value::as_str).unwrap_or("")).collect()
        }
        _ => Vec::new(),
    };
    let names: Vec<&str> = if from_proofs.is_empty() {
        vec![map.get("suite").and_then(Value::as_str).unwrap_or("")]
    } else {
        from_proofs
    };
    let mut seen: Vec<String> = Vec::new();
    for name in names {
        if !name.is_empty() && !seen.iter().any(|s| s == name) {
            seen.push(name.to_string());
        }
    }
    seen
}

impl Stored {
    /// Bash `receipt_suites` on the parsed file; see [`Receipt::suites`].
    #[must_use]
    pub fn suites(&self) -> Vec<String> {
        suites_of(&self.map)
    }

    /// Bash `receipt_field partial false` on the parsed file; see [`Receipt::is_partial`].
    #[must_use]
    pub fn is_partial(&self) -> bool {
        matches!(py_print(self.map.get("partial")).as_str(), "True" | "true")
    }

    /// The `proofs` field as read, for the fold.
    pub(crate) fn proofs_value(&self) -> Option<&Value> {
        self.map.get("proofs")
    }
}
