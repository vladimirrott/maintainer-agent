# What contains a hostile pull request

This agent reviews code written by strangers on a machine holding SSH keys, a
GitHub token and other people's projects. That makes "can a pull request run
code here" the question the whole design turns on.

There are two answers, and the first is the important one.

## 1. Usually, nothing runs at all

`maintainer screen <pr>` decides whether a pull request may be executed **before
anything is built**. It returns `DO NOT EXECUTE` for any diff touching `.rs`,
`.sh`, `.py`, `.js`, `.ts`, a dependency, a build script or a workflow, which is
most of them, and it **fails closed** on anything it cannot classify.

`cargo test` compiles and runs a contributor's code, and `build.rs` runs it at
*compile* time, so `cargo build` is already enough. An unattended run has no
fallback: it reviews by reading and says so in the review.

Not executing is the strongest containment available and it is the default.

## 2. When something must run, it runs like this

Only `maintainer-merge verify` executes contributor code, and only inside a
container. Every flag below is measured by `tests/containment-probe.sh` with the
attack it is supposed to stop, because a flag on a command line is not evidence.

| Control | What it stops | Measured |
|---|---|---|
| `--network=none` | phoning home, fetching a stage two | outbound TCP and DNS both fail |
| `--cap-drop=ALL` | everything from `CAP_NET_RAW` to `CAP_SYS_ADMIN` | `CapEff` is empty |
| `--security-opt=no-new-privileges` | a setuid binary elevating inside | `NoNewPrivs: 1` |
| `--read-only` | tampering with the image | writing `/etc/passwd` fails |
| `--tmpfs /tmp:noexec,nosuid` | dropping and running a payload | the dropped binary will not execute |
| `--pids-limit` | a fork bomb | the bomb hits the wall |
| `--memory`, `--cpus` | starving the host | a 4G balloon fails in a 256m tmpfs |
| `--timeout` | an infinite loop holding a timer for ever | the container dies and none is left behind |
| no host environment | reading `GH_TOKEN` or an API key | a planted canary never appears inside |
| one bind mount | reaching the rest of the disk | writing outside the mount fails |

Run it yourself:

```sh
./tests/containment-probe.sh
```

### The one that had to be learned the hard way

`timeout 60 podman run …` **does not stop the container.** It kills the podman
client, and conmon keeps the payload running. Measured while writing this: two
containers still spinning three minutes after the client was killed, with the
host load average at 5.5.

`podman run --timeout=N` is the control that works, because conmon enforces it.
The probe asserts the stronger property: after an infinite loop, **no container
is left behind**.

## What this is not

**It is not a boundary against a kernel exploit.** Containers share the host
kernel. Namespaces and seccomp raise the cost of an escape; they do not make one
impossible, and the 2026 consensus is that shared-kernel isolation is no longer
adequate for genuinely untrusted code.

Saying that plainly matters more than the table above. Anyone deploying this
should know that the guarantee is "a hostile pull request cannot casually reach
your keys or your network", not "a hostile pull request cannot escape".

**What would close it:** a user-space kernel (gVisor's `runsc`) or a micro-VM
(Firecracker, Kata). Both are a runtime swap rather than a redesign, since every
control above is expressed as flags to one `run` call. `runsc` is the cheaper
step and is tracked as an issue.

**Mount isolation on the host is unavailable here.** On systemd 255 with
`kernel.apparmor_restrict_unprivileged_userns=1`, `ProtectHome`, `BindPaths` and
`InaccessiblePaths` are silently ignored for user units, and `bwrap` fails with
`setting up uid map: Permission denied`. Those directives were removed rather
than left in looking protective: a directive that no-ops reads as a guarantee.

## Rootless podman under a hardened unit

`newuidmap` is setuid, so `NoNewPrivileges` and `RestrictSUIDSGID` stop podman
*establishing* a user namespace, though it can *reuse* one. Measured: cold plus
full hardening failed 10 times out of 10; warm plus full hardening succeeded.
`podman-userns-warmup.service`, unhardened and running one fixed command with no
model output, establishes the namespace first, and the maintainer unit is
ordered after it and stays hardened. Without that ordering, container
verification would silently vanish after a reboot, and a merge gate that quietly
stops verifying still merges.

## Prior art

The design follows the 2026 consensus for sandboxing agent-run code: rootless
podman, drop everything, no network, read-only root, resource caps, and an
honest statement that shared-kernel isolation stops short of a kernel exploit.
See [awesome-sandbox](https://github.com/restyler/awesome-sandbox) and
[Podman as a sandbox for untrusted code](https://oneuptime.com/blog/post/2026-03-18-use-podman-sandbox-untrusted-code/view).
