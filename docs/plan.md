# Plan: the hard parts

Written 2026-09-04. Everything here is either not obvious or has a way of going
wrong that is worth naming before starting. The easy work is not in this file.

## 1. Forty maintainer situations, and what to do with them

**The trap:** turning forty situations into forty eval scenarios. Each scenario
costs a fixture, a rule, a mapping entry and a place in every profile's
`evals.json`, and a suite of forty that nobody reads is worse than seven that
everybody does. The eval suite is a regression check on rules that already
exist, not a place to store ideas.

**The split:**

- **`docs/user-stories.md`** holds all forty. Each one names the situation, what
  the agent must do, what it must not, and **where the governing rule lives**.
  Writing that last column is the work: a story whose rule lives nowhere is a
  gap, and the point of the exercise is to find those.
- A story becomes an **eval scenario** only when it is adversarial: something
  or someone actively trying to get the agent to do the wrong thing. Prompt
  injection is a scenario. "A dependency bump arrives" is not.
- A story becomes a **prompt rule** when the agent would otherwise guess.
- A story becomes **nothing** when the existing doctrine already covers it, and
  saying so explicitly is a result.

**Where the situations come from:** real trackers rather than imagination.
Comet-ml/opik is a good source because it is a young, fast-moving project with
outside contributors, so its issues carry the mundane shapes that break an
unattended agent: a bug report with no reproduction, a feature request that is
really a support question, a stale PR whose author has gone quiet, a report that
is actually about a dependency, a duplicate nobody noticed, a first-time
contributor whose CI cannot run.

**Definition of done:** every story has a rule location or is marked as a gap
with an issue number. The count of gaps is the finding, and I expect it to be
uncomfortable.

## 2. Showing which version is running

**Why it is hard:** the agent is a set of prompts and shell scripts assembled at
run time from a deployed tree that can be older than the repository. There are
three versions in play and they disagree in normal use:

1. the repository checkout (`git describe`),
2. the **deployed** tree in `~/.local/share/maintainer`, which is what actually
   runs,
3. the profile, which can be edited independently of both.

Printing the repository's version would be the wrong one and the most flattering.

**The design:** `install.sh` stamps the deployed tree with the version and
commit it came from, at install time, into `$share/VERSION`. Everything reads
that file, never git:

- `maintainer status` prints it at the top, and **says when it differs from the
  repository checkout**, because a deployed tree three commits behind is the
  single most likely cause of "but I fixed that".
- Every run report opens with it, so a report from six weeks ago says which
  agent wrote it.
- The assembled prompt carries it, so the agent can quote its own version in a
  review without being told.
- `maintainer-doctor` fails when the deployed tree has no stamp at all.

**The trap:** stamping at install time means an edit to the deployed tree is
invisible. That is the right trade: an edited deployment is already broken, and
the stamp should record provenance rather than pretend to be a checksum. The
doctor's existing drift check is the place to catch edits, not the stamp.

## 3. Better UX generally

The commands are correct and the first minute is unfriendly. Concretely:

- **`maintainer` with no arguments prints a docstring.** It should print what
  the state of the world is, which is what someone typing a bare command wants.
- **Errors name a fix.** `maintainer-doctor` does this; nothing else does.
- **`maintainer status` is the front door** and should answer, in one screen:
  which version, which profiles exist, which is posting, what ran, what is due,
  and whether anything failed. It currently answers half of that for one
  profile.
- **A failed run is invisible** unless you read the log. `status` should surface
  it. Issue #3 covers the notification half; this is the "you already typed a
  command, so tell me" half.
- **Colour and alignment.** The doctor uses colour; nothing else does. Cheap.

**The trap:** UX work that changes what the tools *do*. Every change here must
be output-only, or it needs the same mutation proof as anything else.

## 4. Opus with a high thinking budget

**The ask:** run the sysknife profile on Claude Code with Opus and a high
reasoning effort.

**What is actually available:** Claude Code takes `--model`, which the profile
already sets. Reasoning effort is not a CLI flag; the budget is controlled by
`MAX_THINKING_TOKENS` in the environment. So the profile needs a per-task
thinking budget that `lib/backends/claude.sh` exports, and the honest thing is
to name the mechanism in a comment rather than implying a flag exists.

**The trap:** a bigger budget costs money on every run and the last review cost
$4.49. This belongs in the profile, per task, so `review` can think hard and a
`ci` sweep need not.

**Verification:** a run whose transcript shows the budget in effect, not a
setting nobody confirmed reached the process. `/proc/<pid>/environ` on a live
run is the measurement, the same way the `MAINTAINER_FORCE` leak was found.

## 5. The agent maintaining itself, on a timer

`profiles/magent` exists and has run twice by hand at `POST=off`. Turning its
timers on is one command, and it is the last step rather than the first: an
agent that reviews its own repository can change the rules it is reviewed under.

**The order:** land the version stamp first, so a magent run report says which
agent produced it. Then enable review only, leave `POST=off`, and read a week.
`issues` stays off until the review reports are boring.

## 6. Cutting the release

`maintainer-repo release-check` reads the CHANGELOG's Unreleased section, and
that section is currently empty while eight commits have landed since v0.1.0.
Writing it is the work; the tag is one command. The digit moves to **0.2.0**:
the merge gate now refuses a repository with no suite covering the changed
paths, which is a capability that used to succeed and now does not.
