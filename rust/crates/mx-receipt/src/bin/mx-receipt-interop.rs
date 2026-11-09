//! A thin command line over the library, used by `tests/interop.sh` to run the
//! bash gate and this crate against each other's receipts. It is a test
//! helper: the gate's own binaries come later.
//!
//! ```text
//! mx-receipt-interop verify <key-file> <receipt> <pr> [--unattended]
//! mx-receipt-interop write-asserted <key-file> <out> <pr> <head> <proof> <recorded-at> <recorded-by>
//! mx-receipt-interop write-dependency <key-file> <out> <pr> <head> <files> <lines> <pins> <images> <pips> <recorded-at> <recorded-by>
//! mx-receipt-interop write-observed <key-file> <out> <pr> <head> <verify-part|-> <suite> <units> <filter> <mutation> <rc> <failure> <recorded-at> <recorded-by>
//! mx-receipt-interop suites <receipt>
//! mx-receipt-interop partial <receipt>
//! mx-receipt-interop show <dir> <pr>
//! mx-receipt-interop show-list <dir>
//! ```
//!
//! `write-observed` reads `<out>` when it exists and folds into it in part mode,
//! as the gate does. Exit 0 on success, 1 on a refusal (the reason on stderr),
//! 64 on a usage error.

use mx_core::Fact;
use mx_ports::{Fs, FsError};
use mx_receipt::{
    DependencyFacts, ListEntry, Part, Receipt, ReceiptError, Stamp, Stored, plan_fold, show_list,
    show_one, write,
};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

/// The standard filesystem behind the `Fs` port, for this helper only.
struct StdFs;

impl Fs for StdFs {
    fn read(&self, path: &Path) -> Fact<Vec<u8>> {
        match std::fs::read(path) {
            Ok(bytes) => Fact::Known(bytes),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Fact::Absent,
            Err(error) => Fact::Unreadable(error.to_string()),
        }
    }

    fn mtime(&self, _path: &Path) -> Fact<u64> {
        Fact::Unreadable("not needed by this helper".into())
    }

    fn list(&self, path: &Path) -> Fact<Vec<PathBuf>> {
        let Ok(dir) = std::fs::read_dir(path) else { return Fact::Absent };
        let mut files: Vec<PathBuf> =
            dir.filter_map(|entry| entry.ok().map(|e| e.path())).collect();
        files.sort();
        if files.is_empty() { Fact::Absent } else { Fact::Known(files) }
    }

    fn write(&self, path: &Path, contents: &[u8]) -> Result<(), FsError> {
        std::fs::write(path, contents)
            .map_err(|error| FsError { path: path.to_path_buf(), reason: error.to_string() })
    }

    fn remove(&self, path: &Path) -> Result<(), FsError> {
        std::fs::remove_file(path)
            .map_err(|error| FsError { path: path.to_path_buf(), reason: error.to_string() })
    }
}

enum Failure {
    Usage(String),
    Refused(ReceiptError),
}

impl From<ReceiptError> for Failure {
    fn from(error: ReceiptError) -> Self {
        Self::Refused(error)
    }
}

fn arg<'a>(args: &'a [String], index: usize, name: &str) -> Result<&'a str, Failure> {
    args.get(index).map(String::as_str).ok_or_else(|| Failure::Usage(format!("missing <{name}>")))
}

fn number<T: std::str::FromStr>(text: &str, name: &str) -> Result<T, Failure> {
    text.parse().map_err(|_| Failure::Usage(format!("<{name}> must be a number, not '{text}'")))
}

fn key(path: &str) -> Result<mx_receipt::Key, Failure> {
    match StdFs.read(Path::new(path)) {
        Fact::Known(bytes) => Ok(mx_receipt::Key::from_file_bytes(&bytes)?),
        Fact::Absent => Err(ReceiptError::KeyMissing { path: path.to_string() }.into()),
        Fact::Unreadable(reason) => Err(ReceiptError::Store { reason }.into()),
    }
}

fn cmd_verify(args: &[String]) -> Result<Vec<u8>, Failure> {
    let key = key(arg(args, 1, "key-file")?)?;
    let file = arg(args, 2, "receipt")?;
    let pr = arg(args, 3, "pr")?;
    let unattended = args.get(4).is_some_and(|a| a == "--unattended");
    let Fact::Known(bytes) = StdFs.read(Path::new(file)) else {
        return Err(ReceiptError::NoReceipt { pr: pr.to_string() }.into());
    };
    let receipt = Stored::parse(&bytes)?.check(&key, pr, unattended)?;
    if receipt.to_bytes() != bytes {
        return Err(ReceiptError::Shape {
            reason: "the receipt does not write back to its own bytes".into(),
        }
        .into());
    }
    Ok(format!("verified pr={pr} head={} signature={}\n", receipt.head(), receipt.signature())
        .into_bytes())
}

fn cmd_write_asserted(args: &[String]) -> Result<Vec<u8>, Failure> {
    let key = key(arg(args, 1, "key-file")?)?;
    let out = Path::new(arg(args, 2, "out")?);
    let pr: u64 = number(arg(args, 3, "pr")?, "pr")?;
    let stamp = Stamp::new(arg(args, 6, "recorded-at")?, arg(args, 7, "recorded-by")?);
    let receipt =
        Receipt::asserted(pr, arg(args, 4, "head")?, arg(args, 5, "proof")?, &stamp, false)?
            .sign(&key);
    write(&StdFs, out, &receipt)?;
    Ok(Vec::new())
}

fn cmd_write_dependency(args: &[String]) -> Result<Vec<u8>, Failure> {
    let key = key(arg(args, 1, "key-file")?)?;
    let out = Path::new(arg(args, 2, "out")?);
    let pr: u64 = number(arg(args, 3, "pr")?, "pr")?;
    let facts = DependencyFacts {
        files: arg(args, 5, "files")?.to_string(),
        changed_lines: number(arg(args, 6, "lines")?, "lines")?,
        pins_verified: number(arg(args, 7, "pins")?, "pins")?,
        images_verified: number(arg(args, 8, "images")?, "images")?,
        pip_verified: number(arg(args, 9, "pips")?, "pips")?,
    };
    let stamp = Stamp::new(arg(args, 10, "recorded-at")?, arg(args, 11, "recorded-by")?);
    let receipt = Receipt::dependency(pr, arg(args, 4, "head")?, &facts, &stamp).sign(&key);
    write(&StdFs, out, &receipt)?;
    Ok(Vec::new())
}

fn cmd_write_observed(args: &[String]) -> Result<Vec<u8>, Failure> {
    let key = key(arg(args, 1, "key-file")?)?;
    let out = Path::new(arg(args, 2, "out")?);
    let pr_arg = arg(args, 3, "pr")?;
    let head = arg(args, 4, "head")?;
    let verify_part = match arg(args, 5, "verify-part")? {
        "-" => None,
        value => Some(value),
    };
    let part = Part {
        suite: arg(args, 6, "suite")?.to_string(),
        units_run: arg(args, 7, "units")?.to_string(),
        filter: arg(args, 8, "filter")?.to_string(),
        mutation: arg(args, 9, "mutation")?.to_string(),
        mutated_rc: number(arg(args, 10, "rc")?, "rc")?,
        observed_failure: arg(args, 11, "failure")?.to_string(),
    };
    let stamp = Stamp::new(arg(args, 12, "recorded-at")?, arg(args, 13, "recorded-by")?);
    let prior = match StdFs.read(out) {
        Fact::Known(bytes) => Some(bytes),
        Fact::Absent => None,
        Fact::Unreadable(reason) => return Err(ReceiptError::Store { reason }.into()),
    };
    let base = plan_fold(prior.as_deref(), pr_arg, head, verify_part, &key)?;
    let pr: u64 = number(pr_arg, "pr")?;
    let receipt = Receipt::observed(pr, head, base, &part, verify_part, &stamp).sign(&key);
    write(&StdFs, out, &receipt)?;
    Ok(Vec::new())
}

fn cmd_show_list(args: &[String]) -> Result<Vec<u8>, Failure> {
    let entries = show_list(&StdFs, Path::new(arg(args, 1, "dir")?))?;
    if entries.is_empty() {
        return Ok(b"  no receipts recorded\n".to_vec());
    }
    let mut out = String::new();
    for entry in entries {
        match entry {
            ListEntry::Line(line) => {
                out.push_str(&line);
                out.push('\n');
            }
            ListEntry::Unreadable { file, reason } => {
                return Err(ReceiptError::Store { reason: format!("{file}: {reason}") }.into());
            }
        }
    }
    Ok(out.into_bytes())
}

/// Prints what bash `receipt_suites` and `receipt_field partial false` print.
fn cmd_read_field(args: &[String], which: &str) -> Result<Vec<u8>, Failure> {
    let file = arg(args, 1, "receipt")?;
    let Fact::Known(bytes) = StdFs.read(Path::new(file)) else {
        return Err(ReceiptError::NoReceipt { pr: file.to_string() }.into());
    };
    let stored = Stored::parse(&bytes)?;
    let text = if which == "suites" {
        stored.suites().join(" ")
    } else if stored.is_partial() {
        "True".to_string()
    } else {
        "False".to_string()
    };
    Ok(format!("{text}\n").into_bytes())
}

fn run(args: &[String]) -> Result<Vec<u8>, Failure> {
    match arg(args, 0, "command")? {
        "suites" => cmd_read_field(args, "suites"),
        "partial" => cmd_read_field(args, "partial"),
        "verify" => cmd_verify(args),
        "write-asserted" => cmd_write_asserted(args),
        "write-dependency" => cmd_write_dependency(args),
        "write-observed" => cmd_write_observed(args),
        "show" => Ok(show_one(&StdFs, Path::new(arg(args, 1, "dir")?), arg(args, 2, "pr")?)?),
        "show-list" => cmd_show_list(args),
        other => Err(Failure::Usage(format!("unknown command '{other}'"))),
    }
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(output) => {
            use std::io::Write as _;
            if std::io::stdout().write_all(&output).is_err() {
                return ExitCode::from(1);
            }
            ExitCode::SUCCESS
        }
        Err(Failure::Usage(message)) => {
            eprintln!("mx-receipt-interop: {message}");
            ExitCode::from(64)
        }
        Err(Failure::Refused(error)) => {
            eprintln!("mx-receipt-interop: {error}");
            ExitCode::from(1)
        }
    }
}
