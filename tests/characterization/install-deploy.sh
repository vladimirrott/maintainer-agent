#!/usr/bin/env bash
# Characterization: install.sh, everything except the busy-run refusal and
# --uninstall (install-busy.sh and install-uninstall.sh). The flags, the dry run,
# what a real install deploys, the receipt key, the VERSION stamp, the platform
# dispatch, --timers, a tree with fewer profiles than expected, and a missing tool.
#
# Most cases run against a tree whose profiles/ is replaced by three small
# fixtures (ci_fixture_profiles), so the goldens do not move when a real profile
# changes. One case runs the real profiles.
#
# Cases marked "pins current behaviour" record what the bash does today without
# saying it is right. No plan decision in notes covers them yet.
# Sorting: the program globs files in the order of LC_COLLATE. The cases run it
# under LC_ALL=C, so the order pinned here is the C-locale order.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib-inst.sh"
ci_init

TIMERS=(maintainer@magent-issues.timer maintainer@magent-review.timer maintainer@sysknife-audit.timer
        maintainer@sysknife-ci.timer maintainer@sysknife-issues.timer maintainer@sysknife-review.timer)

# --- flags ------------------------------------------------------------------------

case_flag_unknown() {
    ci_fixture_profiles
    ci_snap "$CZ_HOME" > "$CZ_CASE/home.before"; ci_snap "$CZ_TREE" > "$CZ_CASE/tree.before"
    ci_install --bogus
    cz_expect_rc 64
    cz_expect_stdout_empty
    cz_expect_stderr "install.sh: unknown flag --bogus"
    ci_snap "$CZ_HOME" > "$CZ_CASE/home.after"; ci_snap "$CZ_TREE" > "$CZ_CASE/tree.after"
    ci_expect_same_snap "home" "$CZ_CASE/home.before" "$CZ_CASE/home.after"
    ci_expect_same_snap "tree" "$CZ_CASE/tree.before" "$CZ_CASE/tree.after"
}
ci_case "flags: an unknown flag exits 64 with one stderr line and writes nothing" case_flag_unknown

case_flag_unknown_after_valid() {
    ci_fixture_profiles
    ci_install --dry-run --bogus
    cz_expect_rc 64
    cz_expect_stdout_empty
    cz_expect_stderr "install.sh: unknown flag --bogus"
}
ci_case "flags: an unknown flag after a valid one still exits 64 before any output" case_flag_unknown_after_valid

case_flag_positional() {
    ci_install install
    cz_expect_rc 64
    cz_expect_stderr "install.sh: unknown flag install"
}
ci_case "flags: a bare word is an unknown flag" case_flag_positional

case_flag_help() {
    ci_install --help
    cz_expect_rc 64
    cz_expect_stderr "install.sh: unknown flag --help"
}
ci_case "flags: --help is an unknown flag (pins current behaviour)" case_flag_help

case_flag_order() {
    ci_fixture_profiles
    ci_install --timers --dry-run; local a; a="$(cat "$CZ_CASE/stdout")"
    ci_install --dry-run --timers
    cz_expect_rc 0
    cz_check "stdout does not depend on the order of --timers and --dry-run" "$(cat "$CZ_CASE/stdout")" "$a"
    cz_expect_stdout_has "would: systemctl --user enable --now maintainer@sysknife-ci.timer"
}
ci_case "flags: --timers and --dry-run give the same output in either order" case_flag_order

# --- dry run ----------------------------------------------------------------------

case_dry_run_golden() {
    ci_fixture_profiles
    ci_install --dry-run
    cz_expect_rc 0
    cz_expect_stderr_empty
    ci_golden_stream stdout dry-run-linux.txt
}
ci_case "dry run: the Linux output is the golden file and exits 0" case_dry_run_golden

case_dry_run_writes_nothing() {
    ci_fixture_profiles
    ci_snap "$CZ_HOME" > "$CZ_CASE/home.before"; ci_snap "$CZ_TREE" > "$CZ_CASE/tree.before"
    ci_install --dry-run
    cz_expect_rc 0
    ci_snap "$CZ_HOME" > "$CZ_CASE/home.after"; ci_snap "$CZ_TREE" > "$CZ_CASE/tree.after"
    ci_expect_same_snap "home" "$CZ_CASE/home.before" "$CZ_CASE/home.after"
    ci_expect_same_snap "tree" "$CZ_CASE/tree.before" "$CZ_CASE/tree.after"
    cz_expect_no_file "$CZ_SHARE"
    ci_expect_calls systemctl.calls
    ci_expect_calls crontab.calls
}
ci_case "dry run: no file is created or changed and no scheduler tool runs" case_dry_run_writes_nothing

case_dry_run_timers_golden() {
    ci_fixture_profiles
    ci_install --dry-run --timers
    cz_expect_rc 0
    ci_golden_stream stdout dry-run-timers-linux.txt
    ci_expect_calls systemctl.calls
    cz_expect_no_file "$CZ_HOME/.local/share/systemd"
}
ci_case "dry run with --timers: lists the systemctl and touch lines and runs none of them" case_dry_run_timers_golden

case_dry_run_no_git_needed() {
    ci_fixture_profiles
    ci_drop_tool git
    ci_install --dry-run
    cz_expect_rc 0
    cz_expect_stdout_has "  would stamp $CZ_SHARE/VERSION"
}
ci_case "dry run: needs no git to print the VERSION line" case_dry_run_no_git_needed

# Pins current behaviour. The wall loop globs the DEPLOYED deny.json files, and a
# dry run deploys nothing, so the "would generate" line in install.sh is never
# printed on a clean machine.
case_dry_run_without_python() {
    ci_fixture_profiles
    ci_drop_tool python3; ci_drop_tool od; ci_drop_tool git
    ci_install --dry-run
    cz_expect_rc 0
    cz_expect_lacks stdout "would generate"
    cz_expect_stderr_empty
}
ci_case "dry run: needs no python3, od or git and prints no wall lines on a clean machine (pins current behaviour)" case_dry_run_without_python

# --- a real install ---------------------------------------------------------------

case_install_golden() {
    ci_fixture_profiles
    ci_install
    cz_expect_rc 0
    cz_expect_stderr_empty
    ci_golden_stream stdout install-linux.txt
    ci_expect_calls systemctl.calls
}
ci_case "install: the Linux output is the golden file, exits 0 and leaves the timers alone" case_install_golden

# Every deployed file must equal its source. The source is read from the case's
# own tree, so the case does not move when a repository file changes.
case_install_copies_every_file() {
    ci_fixture_profiles
    ci_install
    cz_expect_rc 0
    local n=0 f src dst
    local pairs=()
    for f in run.sh prose-style.md preamble-core.md profile.sh failure-shapes.json defaults.env; do
        pairs+=("$CZ_TREE/lib/$f|$CZ_SHARE/$f")
    done
    for f in "$CZ_TREE"/scripts/*.py; do pairs+=("$f|$CZ_SHARE/scripts/$(basename "$f")"); done
    for f in "$CZ_TREE"/lib/backends/*; do pairs+=("$f|$CZ_SHARE/backends/$(basename "$f")"); done
    for f in maintainer maintainer-merge maintainer-doctor maintainer-repo maintainer-mcp; do
        pairs+=("$CZ_TREE/bin/$f|$CZ_HOME/.local/bin/$f")
    done
    for f in "$CZ_TREE"/platform/linux/*.service "$CZ_TREE"/platform/linux/*.timer; do
        pairs+=("$f|$CZ_HOME/.config/systemd/user/$(basename "$f")")
    done
    pairs+=("$CZ_TREE/platform/linux/run-instance.sh|$CZ_SHARE/run-instance.sh")
    pairs+=("$CZ_TREE/platform/linux/alert.sh|$CZ_SHARE/alert.sh")
    for f in sysknife/profile.env sysknife/deny.json sysknife/prompts/review.md magent/profile.env magent/deny.json; do
        pairs+=("$CZ_TREE/profiles/$f|$CZ_SHARE/profiles/$f")
    done
    for f in "${pairs[@]}"; do
        src="${f%%|*}"; dst="${f#*|}"; n=$((n + 1))
        if [ ! -f "$dst" ]; then cz_note_fail "not deployed: $dst"; continue; fi
        cmp -s "$src" "$dst" || cz_note_fail "deployed file differs from its source: $dst"
    done
    [ "$n" -ge 35 ] || cz_note_fail "only $n file pairs were checked, expected at least 35"
}
ci_case "install: every library file, script, command, unit and profile file lands byte for byte" case_install_copies_every_file

case_install_executables() {
    ci_fixture_profiles
    ci_install
    local f
    for f in "$CZ_SHARE/run.sh" "$CZ_SHARE/run-instance.sh" "$CZ_SHARE/alert.sh" \
             "$CZ_HOME/.local/bin/maintainer" "$CZ_HOME/.local/bin/maintainer-merge" "$CZ_HOME/.local/bin/maintainer-doctor" \
             "$CZ_HOME/.local/bin/maintainer-repo" "$CZ_HOME/.local/bin/maintainer-mcp"; do
        [ -x "$f" ] || cz_note_fail "not executable: $f"
    done
}
ci_case "install: run.sh, run-instance.sh, alert.sh and the five commands are executable" case_install_executables

case_install_exact_file_list() {
    ci_fixture_profiles
    ci_install
    ci_manifest "$CZ_HOME" | awk '{print $2, $3}' > "$CZ_CASE/manifest"
    ci_expect_golden_file install-file-list-linux.txt "$CZ_CASE/manifest"
}
ci_case "install: the set of files created under HOME and their owner bits is the golden list" case_install_exact_file_list

case_install_template_not_deployed() {
    ci_fixture_profiles
    ci_install
    cz_expect_no_file "$CZ_SHARE/profiles/_template"
    cz_expect_file "$CZ_SHARE/profiles/sysknife/profile.env"
    cz_expect_file "$CZ_SHARE/profiles/magent/profile.env"
}
ci_case "install: profiles/_template is not deployed" case_install_template_not_deployed

# The wall for each profile is rendered from its deny.json by scripts/render-settings.py
# with the profile directory and HOME. The case runs the renderer itself on a copy of
# the deployed profile and compares, so a changed argument shows as a different file.
case_install_renders_walls() {
    ci_fixture_profiles
    ci_install
    local p
    for p in magent sysknife; do
        cz_expect_file "$CZ_SHARE/profiles/$p/settings.json"
        cz_expect_file "$CZ_SHARE/profiles/$p/settings-rehearsal.json"
        rm -rf "$CZ_CASE/ref-$p"; cp -r "$CZ_TREE/profiles/$p" "$CZ_CASE/ref-$p"
        ( cd "$CZ_CASE" && env -i PATH="$CZ_CASE/bin:$CZ_TOOLS" HOME="$CZ_HOME" python3 "$CZ_TREE/scripts/render-settings.py" "$CZ_CASE/ref-$p" "$CZ_HOME" > /dev/null )
        cmp -s "$CZ_CASE/ref-$p/settings.json" "$CZ_SHARE/profiles/$p/settings.json" || cz_note_fail "$p/settings.json is not what render-settings.py writes for HOME=$CZ_HOME"
        cmp -s "$CZ_CASE/ref-$p/settings-rehearsal.json" "$CZ_SHARE/profiles/$p/settings-rehearsal.json" || cz_note_fail "$p/settings-rehearsal.json differs from the renderer's"
    done
    grep -qF "Bash($CZ_HOME/.local/bin/maintainer-merge receipt:*)" "$CZ_SHARE/profiles/magent/settings.json" \
        || cz_note_fail "the live wall lacks the receipt rule spelled with this HOME"
}
ci_case "install: each profile's settings.json and settings-rehearsal.json are rendered for this HOME" case_install_renders_walls

case_install_wall_rule_counts() {
    ci_fixture_profiles
    ci_install
    cz_expect_matches stdout '^  magent: [0-9]+ deny rules, [0-9]+ in rehearsal$'
    cz_expect_matches stdout '^  sysknife: [0-9]+ deny rules, [0-9]+ in rehearsal$'
    local live reh
    live="$(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["permissions"]["deny"]))' "$CZ_SHARE/profiles/magent/settings.json")"
    reh="$(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["permissions"]["deny"]))' "$CZ_SHARE/profiles/magent/settings-rehearsal.json")"
    cz_expect_stdout_has "  magent: $live deny rules, $reh in rehearsal"
    [ "$reh" -gt "$live" ] || cz_note_fail "the rehearsal wall ($reh) is not larger than the live wall ($live)"
}
ci_case "install: the printed rule counts equal the rules in the two files written" case_install_wall_rule_counts

case_install_second_run_same_tree() {
    ci_fixture_profiles
    ci_install; ci_manifest "$CZ_HOME" > "$CZ_CASE/m1"
    ci_install
    cz_expect_rc 0
    ci_manifest "$CZ_HOME" > "$CZ_CASE/m2"
    cmp -s "$CZ_CASE/m1" "$CZ_CASE/m2" || cz_note_fail "a second install changed the deployed files: $(diff "$CZ_CASE/m1" "$CZ_CASE/m2" | head -4 | tr '\n' '|')"
    cz_expect_lacks stdout "minted"
}
ci_case "install: a second install leaves every deployed file, the key included, byte for byte the same" case_install_second_run_same_tree

case_install_replaces_not_nests() {
    ci_fixture_profiles
    ci_install
    : > "$CZ_SHARE/profiles/stale.txt"; : > "$CZ_SHARE/backends/stale.sh"; : > "$CZ_SHARE/profiles/magent/stale.md"
    ci_install
    cz_expect_rc 0
    cz_expect_no_file "$CZ_SHARE/profiles/stale.txt"
    cz_expect_no_file "$CZ_SHARE/backends/stale.sh"
    cz_expect_no_file "$CZ_SHARE/profiles/magent/stale.md"
    cz_expect_no_file "$CZ_SHARE/profiles/profiles"
    cz_expect_no_file "$CZ_SHARE/backends/backends"
}
ci_case "install: a second install replaces profiles and backends, it does not nest or keep stale files" case_install_replaces_not_nests

case_install_new_script_deployed() {
    ci_fixture_profiles
    printf 'print(1)\n' > "$CZ_TREE/scripts/zz_new_helper.py"
    ci_install
    cz_expect_rc 0
    cz_expect_file "$CZ_SHARE/scripts/zz_new_helper.py"
}
ci_case "install: every scripts/*.py is deployed, not a fixed list" case_install_new_script_deployed

case_install_real_tree() {
    ci_install
    cz_expect_rc 0
    cz_expect_stderr_empty
    cz_expect_file "$CZ_SHARE/profiles/sysknife/settings.json"
    cz_expect_file "$CZ_SHARE/profiles/magent/settings-rehearsal.json"
    cz_expect_no_file "$CZ_SHARE/profiles/_template"
    cz_expect_matches stdout '^  magent: [0-9]+ deny rules, [0-9]+ in rehearsal$'
    cmp -s "$CZ_TREE/lib/run.sh" "$CZ_SHARE/run.sh" || cz_note_fail "run.sh differs"
    cmp -s "$CZ_TREE/profiles/sysknife/profile.env" "$CZ_SHARE/profiles/sysknife/profile.env" || cz_note_fail "sysknife profile.env differs"
}
ci_case "install: the real profiles deploy, render their walls and leave the template behind" case_install_real_tree

# --- the receipt key ----------------------------------------------------------------

case_key_minted() {
    ci_fixture_profiles
    ci_install
    local k="$CZ_SHARE/receipt.key"
    cz_expect_file "$k"
    cz_check "key mode" "$(ci_mode "$k")" "600"
    cz_check "key length in bytes" "$(wc -c < "$k" | tr -d ' ')" "64"
    grep -qE '^[0-9a-f]{64}$' "$k" || cz_note_fail "the key is not 64 lower-case hex characters on one line"
    cz_expect_stdout_has "  minted a receipt-signing key"
}
ci_case "key: a first install mints 64 hex characters, mode 600, no trailing newline" case_key_minted

case_key_never_printed() {
    ci_fixture_profiles
    ci_install
    local key; key="$(cat "$CZ_SHARE/receipt.key")"
    cz_expect_lacks stdout "$key"
    cz_expect_lacks stderr "$key"
}
ci_case "key: the key value never reaches stdout or stderr" case_key_never_printed

case_key_kept() {
    ci_fixture_profiles
    mkdir -p "$CZ_SHARE"; printf 'existing-key-material' > "$CZ_SHARE/receipt.key"; chmod 640 "$CZ_SHARE/receipt.key"
    ci_install
    cz_expect_rc 0
    cz_check "key content" "$(cat "$CZ_SHARE/receipt.key")" "existing-key-material"
    cz_check "key mode" "$(ci_mode "$CZ_SHARE/receipt.key")" "640"
    cz_expect_lacks stdout "minted"
}
ci_case "key: an existing key is neither replaced nor changed, and nothing says it was minted" case_key_kept

case_key_not_minted_in_dry_run() {
    ci_fixture_profiles
    ci_install --dry-run
    cz_expect_stdout_has "  would mint $CZ_SHARE/receipt.key if absent"
    cz_expect_no_file "$CZ_SHARE/receipt.key"
}
ci_case "key: a dry run says it would mint the key and mints nothing" case_key_not_minted_in_dry_run

# Pins current behaviour. The key is made by a pipeline under pipefail; when od is
# missing the subshell fails, set -e stops the script, and the empty file the
# redirection created stays behind. The next install finds the file and keeps it.
case_key_without_od() {
    ci_fixture_profiles
    ci_drop_tool od
    ci_install
    cz_expect_rc 127
    cz_expect_stderr_has "od: command not found"
    cz_expect_lacks stdout "minted"
    cz_check "the key file the failed pipeline left behind has this many bytes" "$(wc -c < "$CZ_SHARE/receipt.key" | tr -d ' ')" "0"
    cz_expect_no_file "$CZ_SHARE/scripts"
}
ci_case "key: without od the install stops with 127 and leaves an empty receipt.key (pins current behaviour)" case_key_without_od

# --- the VERSION stamp --------------------------------------------------------------

case_version_no_git() {
    ci_fixture_profiles
    ci_install
    cz_expect_rc 0
    cz_check "VERSION" "$(cat "$CZ_SHARE/VERSION")" "version=unknown
commit=unknown
installed_at=2026-01-01T00:00:00+00:00
installed_from=$CZ_TREE"
}
ci_case "version: a tree that is not a git checkout stamps unknown for version and commit" case_version_no_git

case_version_tagged() {
    ci_fixture_profiles; ci_tree_git v9.9.9
    local sha; sha="$("${CI_GIT[@]}" rev-parse --short HEAD)"
    ci_install
    cz_expect_rc 0
    cz_check "VERSION" "$(cat "$CZ_SHARE/VERSION")" "version=v9.9.9
commit=$sha
installed_at=2026-01-01T00:00:00+00:00
installed_from=$CZ_TREE"
}
ci_case "version: a clean checkout on a tag stamps the tag and the short commit" case_version_tagged

case_version_dirty() {
    ci_fixture_profiles; ci_tree_git v9.9.9
    printf '# edit\n' >> "$CZ_TREE/profiles/magent/profile.env"
    ci_install
    cz_check "version line" "$(sed -n 1p "$CZ_SHARE/VERSION")" "version=v9.9.9-dirty"
}
ci_case "version: a modified tracked file adds -dirty" case_version_dirty

case_version_after_tag() {
    ci_fixture_profiles; ci_tree_git v9.9.9
    printf 'x\n' > "$CZ_TREE/extra.txt"; "${CI_GIT[@]}" add -A; "${CI_GIT[@]}" commit -q -m two
    local sha; sha="$("${CI_GIT[@]}" rev-parse --short HEAD)"
    ci_install
    cz_check "version line" "$(sed -n 1p "$CZ_SHARE/VERSION")" "version=v9.9.9-1-g$sha"
    cz_check "commit line" "$(sed -n 2p "$CZ_SHARE/VERSION")" "commit=$sha"
}
ci_case "version: one commit after a tag stamps tag-1-gSHA" case_version_after_tag

case_version_untagged() {
    ci_fixture_profiles; ci_tree_git ""
    local sha; sha="$("${CI_GIT[@]}" rev-parse --short HEAD)"
    ci_install
    cz_check "version line" "$(sed -n 1p "$CZ_SHARE/VERSION")" "version=$sha"
}
ci_case "version: a checkout with no tag stamps the short commit as the version" case_version_untagged

case_version_git_missing() {
    ci_fixture_profiles; ci_tree_git v9.9.9
    ci_drop_tool git
    ci_install
    cz_expect_rc 0
    cz_check "version line" "$(sed -n 1p "$CZ_SHARE/VERSION")" "version=unknown"
    cz_check "commit line" "$(sed -n 2p "$CZ_SHARE/VERSION")" "commit=unknown"
}
ci_case "version: a git checkout without git on PATH stamps unknown" case_version_git_missing

case_version_names_checkout() {
    ci_fixture_profiles
    ci_install
    cz_check "installed_from" "$(sed -n 4p "$CZ_SHARE/VERSION")" "installed_from=$CZ_TREE"
    cz_check "line count" "$(wc -l < "$CZ_SHARE/VERSION" | tr -d ' ')" "4"
}
ci_case "version: the stamp has four lines and installed_from names the checkout that was installed" case_version_names_checkout

# --- the platform dispatch ------------------------------------------------------------

case_platform_darwin() {
    ci_fixture_profiles; ci_uname Darwin
    ci_install --timers
    cz_expect_rc 0
    ci_golden_stream stdout install-darwin.txt
    ci_expect_calls systemctl.calls
    cz_expect_no_file "$CZ_SHARE/run-instance.sh"
    cz_expect_no_file "$CZ_SHARE/alert.sh"
    cz_expect_no_file "$CZ_HOME/.config/systemd/user/maintainer@.service"
}
ci_case "platform: Darwin deploys no units, ignores --timers and points at install-launchd.sh" case_platform_darwin

case_platform_windows() {
    ci_fixture_profiles; ci_uname MINGW64_NT-10.0-19045
    ci_install --timers
    cz_expect_rc 0
    ci_golden_stream stdout install-mingw.txt
    ci_expect_calls systemctl.calls
    cz_expect_no_file "$CZ_SHARE/run-instance.sh"
}
ci_case "platform: MINGW deploys the files, ignores --timers and points at the PowerShell installer" case_platform_windows

case_platform_unknown() {
    ci_fixture_profiles; ci_uname FreeBSD
    ci_install --timers
    cz_expect_rc 0
    ci_golden_stream stdout install-freebsd.txt
    ci_expect_calls systemctl.calls
}
ci_case "platform: an unrecognised system deploys the files, ignores --timers and points at install-cron.sh" case_platform_unknown

case_platform_cygwin_msys() {
    local u
    for u in MSYS_NT-10.0 CYGWIN_NT-10.0; do
        ci_fixture_profiles; ci_uname "$u"
        ci_install
        cz_expect_stdout_has "  platform: Windows"
        cz_expect_stdout_has "  files deployed; register the tasks from PowerShell:"
    done
}
ci_case "platform: MSYS and CYGWIN are treated as Windows" case_platform_cygwin_msys

# --- --timers -------------------------------------------------------------------------

case_timers_golden() {
    ci_fixture_profiles
    ci_install --timers
    cz_expect_rc 0
    ci_golden_stream stdout install-timers-linux.txt
}
ci_case "timers: --timers prints one enabled line per timer and no scheduler hint" case_timers_golden

case_timers_systemctl_calls() {
    ci_fixture_profiles
    ci_install --timers
    local calls=("--user daemon-reload") t
    for t in "${TIMERS[@]}"; do calls+=("--user enable --now $t"); done
    ci_expect_calls systemctl.calls "${calls[@]}"
}
ci_case "timers: daemon-reload first, then enable --now for each timer in glob order" case_timers_systemctl_calls

case_timers_stamp_before_enable() {
    ci_fixture_profiles
    ci_install --timers
    local want=() t
    for t in "${TIMERS[@]}"; do want+=("$t stamp=yes"); done
    ci_expect_calls systemctl.stamps "${want[@]}"
    for t in "${TIMERS[@]}"; do
        [ -f "$CZ_HOME/.local/share/systemd/timers/stamp-$t" ] || cz_note_fail "no stamp file for $t"
        cz_check "size of stamp-$t" "$(wc -c < "$CZ_HOME/.local/share/systemd/timers/stamp-$t" | tr -d ' ')" "0"
    done
}
ci_case "timers: the stamp file for a timer exists before that timer is enabled" case_timers_stamp_before_enable

case_timers_not_enabled_by_default() {
    ci_fixture_profiles
    ci_install
    ci_expect_calls systemctl.calls
    cz_expect_no_file "$CZ_HOME/.local/share/systemd"
}
ci_case "timers: without --timers systemctl is never called and no stamp is written" case_timers_not_enabled_by_default

case_timers_none_found() {
    ci_fixture_profiles
    rm -f "$CZ_TREE"/platform/linux/*.timer
    ci_install --timers
    cz_expect_rc 1
    cz_expect_stderr "install.sh: --timers matched no unit files under $CZ_TREE/platform/linux"
    cz_expect_lacks stdout "  done"
    ci_expect_calls systemctl.calls "--user daemon-reload"
}
ci_case "timers: no timer unit in the tree exits 1 with one stderr line after daemon-reload" case_timers_none_found

case_timers_enable_fails() {
    ci_fixture_profiles
    : > "$CZ_CASE/systemctl.fail.enable"
    ci_install --timers
    cz_expect_rc 1
    cz_expect_lacks stdout "  enabled"
    cz_expect_lacks stdout "  done"
    ci_expect_calls systemctl.stamps "${TIMERS[0]} stamp=yes"
}
ci_case "timers: a failing enable stops the install at the first timer with that exit code (pins current behaviour)" case_timers_enable_fails

case_timers_no_systemctl() {
    ci_fixture_profiles
    ci_drop_tool systemctl
    ci_install --timers
    cz_expect_rc 127
    cz_expect_stderr_has "systemctl: command not found"
    cz_expect_lacks stdout "  done"
    cz_expect_file "$CZ_HOME/.local/bin/maintainer"
}
ci_case "timers: without systemctl the install stops with 127 after the files are deployed (pins current behaviour)" case_timers_no_systemctl

case_timers_linux_without_timers_ok_no_systemctl() {
    ci_fixture_profiles
    ci_drop_tool systemctl
    ci_install
    cz_expect_rc 0
    cz_expect_stdout_has "  timers not touched (pass --timers to enable them)"
}
ci_case "timers: a plain install does not need systemctl" case_timers_linux_without_timers_ok_no_systemctl

# --- fewer profiles than expected -----------------------------------------------------

# Pins current behaviour. install.sh refuses a deployed tree with no sysknife
# profile, after it has copied everything, because that is the profile it
# probes. A tree with only the magent profile therefore cannot install.
case_one_profile_magent_only() {
    ci_fixture_profiles; rm -rf "$CZ_TREE/profiles/sysknife"
    ci_install
    cz_expect_rc 1
    cz_expect_stderr "install.sh: profiles did not land where run.sh expects"
    cz_expect_lacks stdout "  done"
    cz_expect_file "$CZ_SHARE/profiles/magent/profile.env"
    cz_expect_file "$CZ_HOME/.local/bin/maintainer"
}
ci_case "profiles: a tree with only magent copies everything, then exits 1 for the missing sysknife (pins current behaviour)" case_one_profile_magent_only

case_one_profile_sysknife_only() {
    ci_fixture_profiles; rm -rf "$CZ_TREE/profiles/magent"
    ci_install
    cz_expect_rc 0
    cz_expect_stdout_has "  sysknife: "
    cz_expect_lacks stdout "magent:"
    cz_expect_no_file "$CZ_SHARE/profiles/magent"
}
ci_case "profiles: a tree with only sysknife installs" case_one_profile_sysknife_only

case_one_profile_dry_run_does_not_check() {
    ci_fixture_profiles; rm -rf "$CZ_TREE/profiles/sysknife"
    ci_install --dry-run
    cz_expect_rc 0
    cz_expect_stderr_empty
}
ci_case "profiles: a dry run on a tree with only magent exits 0, the landing check is skipped" case_one_profile_dry_run_does_not_check

case_no_profiles() {
    ci_fixture_profiles; rm -rf "$CZ_TREE/profiles/"*
    ci_install
    cz_expect_rc 1
    cz_expect_stderr "install.sh: profiles did not land where run.sh expects"
}
ci_case "profiles: an empty profiles directory exits 1 with the landing message" case_no_profiles

case_profile_without_deny_json() {
    ci_fixture_profiles; rm -f "$CZ_TREE/profiles/magent/deny.json"
    ci_install
    cz_expect_rc 0
    cz_expect_lacks stdout "magent:"
    cz_expect_no_file "$CZ_SHARE/profiles/magent/settings.json"
    cz_expect_file "$CZ_SHARE/profiles/sysknife/settings.json"
}
ci_case "profiles: a profile with no deny.json is deployed without a wall and the install goes on" case_profile_without_deny_json

# --- the deny wall step -----------------------------------------------------------------

case_wall_failure() {
    ci_fixture_profiles
    printf 'import sys\nsys.exit(3)\n' > "$CZ_TREE/scripts/render-settings.py"
    ci_install
    cz_expect_rc 1
    cz_expect_stderr "install.sh: generating the deny wall failed"
    cz_expect_no_file "$CZ_HOME/.local/bin/maintainer"
}
ci_case "wall: a failing render-settings.py exits 1 before the commands are copied" case_wall_failure

case_wall_without_python() {
    ci_fixture_profiles
    ci_drop_tool python3
    ci_install
    cz_expect_rc 1
    cz_expect_stderr_has "python3: command not found"
    cz_expect_stderr_has "install.sh: generating the deny wall failed"
    cz_expect_no_file "$CZ_HOME/.local/bin/maintainer"
}
ci_case "wall: without python3 the install exits 1 with the same message" case_wall_without_python

cz_finish
