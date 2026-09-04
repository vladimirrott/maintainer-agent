# Going public

**Done on 2026-09-03**, except the social preview, which has no API. This page
stays as the record of what was applied and how to reapply it.

## 1. Flip the visibility — done

```sh
gh repo edit vladimirrott/maintainer-agent --visibility public --accept-visibility-change-consequences
```

Read [the leak check's own scope](#4-what-the-leak-check-does-and-does-not-cover)
first.

## 2. Branch protection — done

Refused with `Upgrade to GitHub Pro or make this repository public` while
private, and free the moment it is public. The applied rule requires **the four
gates**, **shellcheck**, **the Windows installer parses** and **trufflehog**,
taken from the check names GitHub actually reports rather than from the job
names in the file, because protection naming a check that never appears can
never be satisfied:

```sh
gh api -X PUT repos/vladimirrott/maintainer-agent/branches/main/protection --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["the four gates", "shellcheck", "the Windows installer parses", "trufflehog"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {"required_approving_review_count": 1},
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
```

`strict` is the one that matters: it requires a branch to be up to date with
`main` before merging, which is the same condition `maintainer-merge` enforces
through `mergeStateStatus`. A green board on a stale branch describes a tree
that is not the one being merged.

`enforce_admins` is false on purpose. An agent cannot merge here at all, and the
person who can needs a way to land a fix when CI itself is broken.

## 3. The social preview — STILL NOT DONE

Confirmed still missing on 2026-09-04:

```sh
$ gh api repos/vladimirrott/maintainer-agent --jq .open_graph_image_url
null
```

There is no REST endpoint for it, so it cannot be scripted. Settings, General,
Social preview, Upload an image, then pick `assets/social-preview.png`. It is
1280x640 and 49KB, which is the size GitHub asks for. Until it is uploaded,
every link to this repository on Slack, X or Hacker News renders GitHub's
default grey card.

## 4. What the leak check does and does not cover

`tests/run-tests.sh` fails if an employer name appears anywhere in the tree, and
separately if any tool names a repository or a GitHub account in code. Both are
mutation-proved.

Neither covers everything a public repository exposes. Before flipping, read:

- `profiles/sysknife/` and `profiles/magent/`, which are live operating profiles
  and name a real repository, a real GitHub login and a path on this machine.
  That is all public information already, and it is deliberate: they are the two
  worked examples anyone adopting this will read.
- `docs/lessons.md`, which describes every hole this project has had, including
  the ones that were live for a day. Publishing it is the point. Each entry ends
  in the guard that closed it, and every guard has a test that goes red when the
  hole is reopened.
- `~/.local/state/*/runs/`, which is **not** in the repository and should stay
  that way. The audit trail names pull requests, contributors and reviews.

## 5. Maintainers

`@V3RNE42` (Julio Cabanillas) holds **admin**, matching his standing on
sysknife. A personal repository has only pull, push and admin: `maintain`, the
role that is literally named for this, exists on organization repositories only,
which is why sysknife can grant it and this cannot.

Upgrading a **pending** invitation does not work through the collaborators
endpoint, which returns the existing invitation unchanged. Patch the invitation:

```sh
gh api -X PATCH repos/vladimirrott/maintainer-agent/invitations/<id> -f permissions=admin
```

## 6. Afterwards

- Watch the first outside issue. `.github/ISSUE_TEMPLATE/config.yml` turns off
  blank issues, so anything that arrives has gone through a template.
- The agent's own tracker (`profiles/magent`) stays at `POST=off` until you have
  read a week of its reports. Turning it on is one line in `profile.env`.
