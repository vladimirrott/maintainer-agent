# Two-day task: the sysknife issue tracker

Invoke the `sysknife-issues` skill and follow it. Read
`references/assignment.md` before proposing any offer and obey its rules.

1. Sweep the open issues. Verify a sample still reproduces at current `main`, and
   correct any body that has gone stale. Contributors work from those bodies, and
   a wrong figure costs them a wasted evening.
2. **Assign, do not only label.** When somebody says they are taking an issue,
   apply `claimed` AND assign them. Two calls, and the label is the one that
   goes second, so a refused assignment cannot leave a label standing alone:

       gh api -X POST repos/lacs-project/sysknife/issues/N/assignees \
           -f 'assignees[]=<user>'
       gh issue edit N --repo lacs-project/sysknife --add-label claimed

   Use the REST call, not `gh issue edit --add-assignee`. The edit resolves the
   login through GraphQL first and answers `'<user>' not found` for an outside
   contributor; on #272 it refused atanishka308 and the REST POST assigned them
   on the next line. GitHub's `/assignees/{user}` check is equally useless: it
   returns 404 for every non-collaborator while the POST succeeds for anyone who
   has commented on the issue. A label is invisible to their dashboard and to
   `assignee:@me`; an assignment is the same promise where GitHub can see it.
   `maintainer claims` lists every claim, who holds it, how long they have been
   quiet, and which ones carry a label and no assignee.

3. Check `claimed` labels. Anything claimed roughly a week with no branch gets a
   check-in that offers an exit, in the shape used on #219 and #248. Release a
   claim that has already had one unanswered check-in, warmly, and say the issue
   is theirs again on request. A release takes all three: the comment, then
   `--remove-label claimed --remove-assignee <user>`, and the comment must end
   with `<!-- maintainer: claim-released -->`. A release and an offer are the
   same sentence to the same person, so without that marker `maintainer offers`
   reads the release as an offer and keeps the issue out of the pool.
4. **Run `maintainer offers` before offering anything.** It lists, per person,
   how many open issues they hold and how many they have never answered, and
   names anyone already over the one-offer rule. That rule was prose until
   2026-09-04 and a single run had already made three offers to one person.
   Somebody who holds nothing does not appear in that table at all; that is what
   an eligible person looks like.

   It also names the issues themselves. **Offer only from the `free to offer`
   list on the first line**, and never an issue that appears under
   `DOUBLE-BOOKED`. Both exist because on 2026-09-07 a batch of offers picked
   issues by hand while the tool printed only a count of free ones. Seven issues
   ended up pointed at two people each and #342 at three, none of whom were told
   about the others. Whoever finishes second on a double-booked issue wasted
   their evening, so this is the person-side rule applied to the other side of
   the pairing.

5. Make at most **two** offers per run, and only under the skill's rules: one open
   offer per person, never to somebody with an unanswered one (check with
   `gh api "search/issues?q=repo:lacs-project/sysknife+mentions:USER+is:issue+is:open"`),
   prefer people active in the last 72 hours, and match on the shape they
   demonstrated rather than the directories they touched.
4. Close any merged PR thread with exactly one next-issue invite.
5. If the tracker is short of `good first issue` + `easy` work that needs no VM,
   no live provider and no maintainer credentials, file some. Verify each defect
   at a named SHA before writing it up, then file it with
   `maintainer file-issue --title ... --body-file ... --fingerprint <stable key> --label "good first issue" --label easy`.
   A bare `gh issue create` is denied: `file-issue` is the only path, because it
   deduplicates by fingerprint. That is the guard that #342 and #343 needed,
   filed nine minutes apart with the same title. Key the fingerprint to the
   defect, not today's wording.
6. Read `references/twir.md`. If a This Week in Rust CfP submission is due, say so
   in the report with the three issues you would list and why. **Do not open that
   PR**; it goes to another organisation's repository and Vladimir files it.

Post the comments, apply the labels, file the issues. Two offers is a ceiling, not
a target: a run that correctly makes none is a good run.

## Reserved issues: whatever carries `twir-listed` today

Issues listed in a This Week in Rust Call for Participation are held for
strangers arriving from that listing. The label is the record; a number written
into a prompt is not. On 2026-09-23 this section still named #345, #327 and
#356, all three closed weeks earlier, and said nothing about the seven open
issues carrying the label then. A hold that names numbers goes stale in the
direction that costs something.

Ask the label, every run, before naming any issue to anyone:

```sh
gh issue list --repo lacs-project/sysknife --label twir-listed --state open \
    --json number --jq '[.[].number] | join(" ")'
```

Anything it returns is off limits: do not offer it, assign it, name it as a next
step, or add it to a stale-claim check-in. Removing the label is a human
decision; you never remove it.

