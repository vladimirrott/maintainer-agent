#!/usr/bin/env python3
"""refresh() must say when a PR head could not be fetched.

The fetch of refs/pull/N/head:pN used to discard its return code, so a failed
fetch left the old pN in place and the run reviewed stale code with no note.
Run: python3 -B tests/test_refresh_pr_fetch.py
"""
import importlib.machinery
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GIT_ID = ["-c", "user.name=test", "-c", "user.email=test@example.invalid"]


def git(*args, cwd=None):
    return subprocess.run(["git", *GIT_ID, *args], cwd=cwd, check=True,
                          capture_output=True, text=True).stdout.strip()


def load_maintainer(repo: Path, state: Path):
    # Environment first: the module reads its repository and state at import.
    os.environ["MAINTAINER_REPO"] = str(repo)
    os.environ["MAINTAINER_STATE"] = str(state)
    sys.argv = ["maintainer", "--help"]  # skip profile resolution
    path = str(ROOT / "bin" / "maintainer")
    loader = importlib.machinery.SourceFileLoader("maintainer_under_test", path)
    spec = importlib.util.spec_from_loader("maintainer_under_test", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class RefreshFetchFailure(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="refresh-fetch-"))
        origin = self.tmp / "origin.git"
        seed = self.tmp / "seed"
        clone = self.tmp / "clone"
        git("init", "-q", "--bare", "-b", "main", str(origin))
        git("init", "-q", "-b", "main", str(seed))
        (seed / "f.txt").write_text("v1\n")
        git("add", "f.txt", cwd=seed)
        git("commit", "-q", "-m", "init", cwd=seed)
        git("remote", "add", "origin", str(origin), cwd=seed)
        git("push", "-q", "origin", "main", cwd=seed)
        git("clone", "-q", str(origin), str(clone))
        # No refs/pull/41/head exists on origin: the fetch must fail.
        self.mod = load_maintainer(clone, self.tmp / "state")
        self.mod.REPO = clone
        self.mod.gh_list = lambda *a, **k: [{"number": 41, "headRefOid": "0" * 40,
                                             "updatedAt": "2026-01-01T00:00:00Z",
                                             "title": "t", "author": {"login": "a"}}]

    def test_failed_pr_head_fetch_is_noted(self):
        _, _, _, notes = self.mod.refresh()
        self.assertIn("PR #41 head not fetched, local p41 is stale", notes,
                      f"expected a stale-pN note, got notes={notes!r}")


if __name__ == "__main__":
    unittest.main()
