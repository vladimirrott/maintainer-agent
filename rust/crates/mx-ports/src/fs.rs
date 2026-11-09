use crate::{Effect, EffectLog, lock};
use mx_core::Fact;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use thiserror::Error;

/// A write to the filesystem failed.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
#[error("{}: {reason}", path.display())]
pub struct FsError {
    pub path: PathBuf,
    pub reason: String,
}

/// The filesystem, as the programs use it.
///
/// Reads return a [`Fact`]: a missing file is [`Fact::Absent`] and a file that
/// cannot be read is [`Fact::Unreadable`]. A cadence gate that treats a
/// permission error as "never ran" would run twice, so the two stay apart.
pub trait Fs {
    /// The contents of a file.
    fn read(&self, path: &Path) -> Fact<Vec<u8>>;

    /// A file's modification time, in seconds since the Unix epoch.
    fn mtime(&self, path: &Path) -> Fact<u64>;

    /// The entries of a directory, sorted. A directory with no entries is absent.
    fn list(&self, path: &Path) -> Fact<Vec<PathBuf>>;

    /// Writes a file, creating it or replacing it.
    fn write(&self, path: &Path, contents: &[u8]) -> Result<(), FsError>;

    /// Removes a file.
    fn remove(&self, path: &Path) -> Result<(), FsError>;
}

/// One call to an [`Fs`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FsEffect {
    Read(PathBuf),
    Mtime(PathBuf),
    List(PathBuf),
    Write { path: PathBuf, contents: Vec<u8> },
    Remove(PathBuf),
}

#[derive(Debug, Default)]
struct State {
    files: BTreeMap<PathBuf, (Vec<u8>, u64)>,
    unreadable: BTreeMap<PathBuf, String>,
    write_failures: BTreeMap<PathBuf, String>,
    now: u64,
}

/// An in-memory filesystem. Directories exist while a file lies under them.
#[derive(Debug)]
pub struct FakeFs {
    state: Mutex<State>,
    log: EffectLog,
}

impl FakeFs {
    /// An empty filesystem whose clock shows 0.
    #[must_use]
    pub fn new(log: &EffectLog) -> Self {
        Self { state: Mutex::new(State::default()), log: log.clone() }
    }

    /// Adds a file with a modification time, without recording a call.
    pub fn put(&self, path: impl Into<PathBuf>, contents: impl Into<Vec<u8>>, mtime: u64) {
        lock(&self.state).files.insert(path.into(), (contents.into(), mtime));
    }

    /// Makes reads of `path` fail with `reason`.
    pub fn make_unreadable(&self, path: impl Into<PathBuf>, reason: impl Into<String>) {
        lock(&self.state).unreadable.insert(path.into(), reason.into());
    }

    /// Makes writes and removals of `path` fail with `reason`.
    pub fn fail_writes_to(&self, path: impl Into<PathBuf>, reason: impl Into<String>) {
        lock(&self.state).write_failures.insert(path.into(), reason.into());
    }

    /// Sets the time a later `write` stamps on its file.
    pub fn set_now(&self, unix_secs: u64) {
        lock(&self.state).now = unix_secs;
    }

    /// The contents of a file, without recording a call.
    #[must_use]
    pub fn peek(&self, path: impl AsRef<Path>) -> Option<Vec<u8>> {
        lock(&self.state).files.get(path.as_ref()).map(|(contents, _)| contents.clone())
    }
}

impl Fs for FakeFs {
    fn read(&self, path: &Path) -> Fact<Vec<u8>> {
        self.log.push(Effect::Fs(FsEffect::Read(path.to_path_buf())));
        let state = lock(&self.state);
        if let Some(reason) = state.unreadable.get(path) {
            return Fact::Unreadable(reason.clone());
        }
        state.files.get(path).map(|(contents, _)| contents.clone()).into()
    }

    fn mtime(&self, path: &Path) -> Fact<u64> {
        self.log.push(Effect::Fs(FsEffect::Mtime(path.to_path_buf())));
        let state = lock(&self.state);
        if let Some(reason) = state.unreadable.get(path) {
            return Fact::Unreadable(reason.clone());
        }
        state.files.get(path).map(|(_, mtime)| *mtime).into()
    }

    fn list(&self, path: &Path) -> Fact<Vec<PathBuf>> {
        self.log.push(Effect::Fs(FsEffect::List(path.to_path_buf())));
        let state = lock(&self.state);
        if let Some(reason) = state.unreadable.get(path) {
            return Fact::Unreadable(reason.clone());
        }
        let entries: Vec<PathBuf> =
            state.files.keys().filter(|file| file.parent() == Some(path)).cloned().collect();
        if entries.is_empty() { Fact::Absent } else { Fact::Known(entries) }
    }

    fn write(&self, path: &Path, contents: &[u8]) -> Result<(), FsError> {
        self.log.push(Effect::Fs(FsEffect::Write {
            path: path.to_path_buf(),
            contents: contents.to_vec(),
        }));
        let mut state = lock(&self.state);
        if let Some(reason) = state.write_failures.get(path) {
            return Err(FsError { path: path.to_path_buf(), reason: reason.clone() });
        }
        let now = state.now;
        state.files.insert(path.to_path_buf(), (contents.to_vec(), now));
        Ok(())
    }

    fn remove(&self, path: &Path) -> Result<(), FsError> {
        self.log.push(Effect::Fs(FsEffect::Remove(path.to_path_buf())));
        let mut state = lock(&self.state);
        if let Some(reason) = state.write_failures.get(path) {
            return Err(FsError { path: path.to_path_buf(), reason: reason.clone() });
        }
        match state.files.remove(path) {
            Some(_) => Ok(()),
            None => Err(FsError { path: path.to_path_buf(), reason: "no such file".to_string() }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fs() -> (FakeFs, EffectLog) {
        let log = EffectLog::new();
        (FakeFs::new(&log), log)
    }

    #[test]
    fn a_missing_file_is_absent_and_not_unreadable() {
        let (fs, _) = fs();
        assert_eq!(fs.read(Path::new("/state/last-review.json")), Fact::Absent);
        assert_eq!(fs.mtime(Path::new("/state/last-review.json")), Fact::Absent);
    }

    #[test]
    fn a_file_that_cannot_be_read_is_unreadable_and_not_absent() {
        let (fs, _) = fs();
        fs.put("/state/last-review.json", "{}", 5);
        fs.make_unreadable("/state/last-review.json", "permission denied");
        assert_eq!(
            fs.read(Path::new("/state/last-review.json")),
            Fact::Unreadable("permission denied".to_string())
        );
        assert!(fs.mtime(Path::new("/state/last-review.json")).is_unreadable());
    }

    #[test]
    fn a_put_file_reads_back_with_its_mtime() {
        let (fs, _) = fs();
        fs.put("/a/b", "hello", 42);
        assert_eq!(fs.read(Path::new("/a/b")), Fact::Known(b"hello".to_vec()));
        assert_eq!(fs.mtime(Path::new("/a/b")), Fact::Known(42));
    }

    #[test]
    fn write_stamps_the_current_fake_time_and_replaces_contents() {
        let (fs, _) = fs();
        fs.set_now(900);
        fs.write(Path::new("/a/b"), b"one").unwrap();
        fs.write(Path::new("/a/b"), b"two").unwrap();
        assert_eq!(fs.read(Path::new("/a/b")), Fact::Known(b"two".to_vec()));
        assert_eq!(fs.mtime(Path::new("/a/b")), Fact::Known(900));
    }

    #[test]
    fn a_failing_write_reports_the_path_and_changes_nothing() {
        let (fs, _) = fs();
        fs.put("/a/b", "old", 1);
        fs.fail_writes_to("/a/b", "disk full");
        let error = fs.write(Path::new("/a/b"), b"new").unwrap_err();
        assert_eq!(error, FsError { path: PathBuf::from("/a/b"), reason: "disk full".to_string() });
        assert_eq!(fs.peek("/a/b"), Some(b"old".to_vec()));
    }

    #[test]
    fn remove_deletes_a_file_and_refuses_a_missing_one() {
        let (fs, _) = fs();
        fs.put("/a/b", "x", 1);
        fs.remove(Path::new("/a/b")).unwrap();
        assert_eq!(fs.peek("/a/b"), None);
        assert!(fs.remove(Path::new("/a/b")).is_err());
    }

    #[test]
    fn list_gives_sorted_children_and_absent_for_an_empty_directory() {
        let (fs, _) = fs();
        fs.put("/d/b", "", 1);
        fs.put("/d/a", "", 1);
        fs.put("/d/sub/c", "", 1);
        assert_eq!(
            fs.list(Path::new("/d")),
            Fact::Known(vec![PathBuf::from("/d/a"), PathBuf::from("/d/b")])
        );
        assert_eq!(fs.list(Path::new("/nowhere")), Fact::Absent);
    }

    #[test]
    fn every_call_is_recorded_in_order_with_its_arguments() {
        let (fs, log) = fs();
        let _ = fs.read(Path::new("/r"));
        fs.write(Path::new("/w"), b"data").unwrap();
        let _ = fs.mtime(Path::new("/w"));
        let _ = fs.list(Path::new("/"));
        fs.remove(Path::new("/w")).unwrap();
        assert_eq!(
            log.entries(),
            vec![
                Effect::Fs(FsEffect::Read(PathBuf::from("/r"))),
                Effect::Fs(FsEffect::Write {
                    path: PathBuf::from("/w"),
                    contents: b"data".to_vec()
                }),
                Effect::Fs(FsEffect::Mtime(PathBuf::from("/w"))),
                Effect::Fs(FsEffect::List(PathBuf::from("/"))),
                Effect::Fs(FsEffect::Remove(PathBuf::from("/w"))),
            ]
        );
    }
}
