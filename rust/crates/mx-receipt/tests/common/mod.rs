//! Shared fixtures for the receipt tests.
#![allow(dead_code)]

use mx_receipt::{Key, pyjson};
use serde_json::{Map, Value};

/// Read at run time from the repository's golden directory. A missing file
/// fails the test that asks for it; it never reads as an empty vector.
pub fn golden(name: &str) -> Vec<u8> {
    let path =
        format!("{}/../../../tests/characterization/golden/{name}", env!("CARGO_MANIFEST_DIR"));
    std::fs::read(&path)
        .unwrap_or_else(|error| panic!("cannot read the golden file {path}: {error}"))
}

pub fn golden_key() -> Vec<u8> {
    golden("receipt.key")
}

pub fn golden_receipt() -> String {
    String::from_utf8(golden("receipt-asserted.json")).unwrap()
}
pub const GOLDEN_HEAD: &str = "cc5e01302bbd828fbf516fca54e1a6e12738de7c";
pub const FIXTURE_OBSERVED: &str = include_str!("../fixtures/observed-two-suites.json");
pub const FIXTURE_DEPENDENCY: &str = include_str!("../fixtures/dependency.json");

pub fn key() -> Key {
    Key::from_file_bytes(&golden_key()).unwrap()
}

pub fn parse(text: &str) -> Map<String, Value> {
    match serde_json::from_str::<Value>(text).unwrap() {
        Value::Object(map) => map,
        other => panic!("not an object: {other}"),
    }
}

/// A receipt file for `body`, signed the way the gate signs it: the HMAC of the
/// body written with `json.dump(indent=2)`, the signature appended last.
pub fn signed(mut body: Map<String, Value>) -> Vec<u8> {
    body.shift_remove("signature");
    let signature = key().sign(pyjson::dumps(&Value::Object(body.clone())).as_bytes());
    body.insert("signature".into(), Value::String(signature));
    pyjson::dumps(&Value::Object(body)).into_bytes()
}

/// An observed-kind body for pull request 7 at the golden head, with the given suites.
pub fn body(extra: &[(&str, Value)]) -> Map<String, Value> {
    let mut map = parse(&format!(
        r#"{{"pr": 7, "head": "{GOLDEN_HEAD}", "kind": "observed", "proof": "p", "recorded_at": "2026-01-01T00:00:00+00:00", "recorded_by": "fixture-user"}}"#
    ));
    for (name, value) in extra {
        map.insert((*name).to_string(), value.clone());
    }
    map
}
