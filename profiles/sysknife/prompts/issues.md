# Two-day task: the sysknife issue tracker

Invoke the `sysknife-issues` skill and follow it. Read
`references/assignment.md` before proposing any offer and obey its rules.

1. Sweep the open issues. Verify a sample still reproduces at current `main`, and
   correct any body that has gone stale. Contributors work from those bodies, and
   a wrong figure costs them a wasted evening.
2. **Assign, do not only label.** When somebody says they are taking an issue,
   apply `claimed` AND assign them:
   `gh issue edit N --repo lacs-project/sysknife --add-assignee <user>`.
   GitHub's `/assignees/{user}` endpoint returns 404 for a non-collaborator and
   the assignment still succeeds for anyone who has commented on the issue, so
   the check is not the answer; try the assignment. A label is invisible to
   their dashboard and to `assignee:@me`; an assignment is the same promise
   where GitHub can see it. `maintainer claims` lists every claim, who holds it,
   how long they have been quiet, and which ones carry a label and no assignee.

3. Check `claimed` labels. Anything claimed roughly a week with no branch gets a
   check-in that offers an exit, in the shape used on #219 and #248. Release a
   claim that has already had one unanswered check-in, warmly, and say the issue
   is theirs again on request.
4. **Run `maintainer offers` before offering anything.** It lists, per person,
   how many open issues they hold and how many they have never answered, and
   names anyone already over the one-offer rule. That rule was prose until
   2026-09-04 and a single run had already made three offers to one person.
   Somebody who holds nothing does not appear in that table at all; that is what
   an eligible person looks like.

5. Make at most **two** offers per run, and only under the skill's rules: one open
   offer per person, never to somebody with an unanswered one (check with
   `gh api "search/issues?q=repo:lacs-project/sysknife+mentions:USER+is:issue+is:open"`),
   prefer people active in the last 72 hours, and match on the shape they
   demonstrated rather than the directories they touched.
4. Close any merged PR thread with exactly one next-issue invite.
5. If the tracker is short of `good first issue` + `easy` work that needs no VM,
   no live provider and no maintainer credentials, file some. Verify each defect
   at a named SHA before writing it up.
6. Read `references/twir.md`. If a This Week in Rust CfP submission is due, say so
   in the report with the three issues you would list and why. **Do not open that
   PR**; it goes to another organisation's repository and Vladimir files it.

Post the comments, apply the labels, file the issues. Two offers is a ceiling, not
a target: a run that correctly makes none is a good run.

## Reserved issues: do not offer #345, #327 or #356

These carry the **`twir-listed`** label and are listed in
rust-lang/this-week-in-rust#8705 for the 2026-09-09 issue. They are held for
strangers arriving from that listing.

Do not offer them, assign them, name them as a next step in a review, or add
them to a stale-claim check-in. This holds even when a contributor has just
merged something and one of them is the obvious match; that is exactly when the
mistake gets made. Pick a different issue.

Check before naming any issue to anyone:

```sh
gh issue view N --repo lacs-project/sysknife --json labels --jq '[.labels[].name]'
```

The reservation lifts after 2026-09-09. Do not remove the label before then.
