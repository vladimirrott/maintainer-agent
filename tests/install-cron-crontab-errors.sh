#!/usr/bin/env bash
# install-cron.sh must not read a failed `crontab -l` as an empty crontab.
# Stubs crontab on PATH; the user's other entries must survive a spool error.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
installer="$root/platform/posix/install-cron.sh"
marker="# maintainer-agent (magent)"
fail=0

work="$(mktemp -d)" || exit 1
trap 'rm -rf "$work"' EXIT
S="$work"
mkdir -p "$S/bin" "$S/home/.local/share/maintainer/profiles"
cp -r "$root/profiles/magent" "$S/home/.local/share/maintainer/profiles/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$S/home/.local/share/maintainer/run.sh"
chmod +x "$S/home/.local/share/maintainer/run.sh"
cat > "$S/bin/crontab" <<'EOF'
#!/usr/bin/env bash
F=$HOME/fake.crontab
if [ "$1" = "-l" ]; then
  [ -n "${FAIL_L:-}" ] && { echo "crontab: temporary failure reading spool" >&2; exit 1; }
  if [ ! -f "$F" ]; then
    if [ "${LC_ALL:-}" = C ]; then echo "no crontab for u" >&2; else echo "Keine crontab für u" >&2; fi
    exit 1
  fi
  cat "$F"; exit 0
fi
cat > "$F"
EOF
chmod +x "$S/bin/crontab"

# $1 = FAIL_L value ("" for none). Leaves the installer's exit code in rc.
run_installer() {
    # LC_ALL is German, as on a localized system: the stub's "no crontab" text is then not English.
    HOME="$S/home" FAIL_L="$1" LC_ALL=de_DE.UTF-8 PATH="$S/bin:$PATH" MAINTAINER_PROFILE=magent \
        bash "$installer" >"$S/out" 2>&1
    rc=$?
}

# Case 1: a spool error must stop the install and leave the crontab byte-identical.
printf '0 3 * * * /home/u/backup.sh\n30 4 * * 1 /home/u/other.sh\n' > "$S/home/fake.crontab"
cp "$S/home/fake.crontab" "$S/before"
run_installer 1
if [ "$rc" != 0 ] && cmp -s "$S/before" "$S/home/fake.crontab" && grep -q 'crontab -l failed' "$S/out"; then
    echo "  PASS  a crontab -l spool error leaves the crontab untouched"
else
    changed=no; cmp -s "$S/before" "$S/home/fake.crontab" || changed=yes
    echo "  FAIL  crontab -l error: installer exited $rc, crontab changed=$changed"
    fail=1
fi

# Case 2: "no crontab for" is the one failure that means an empty list; install goes ahead.
rm -f "$S/home/fake.crontab"
run_installer ""
if [ "$rc" = 0 ] && grep -qF "$marker" "$S/home/fake.crontab"; then
    echo "  PASS  with no crontab yet, the install still writes the maintainer block"
else
    echo "  FAIL  no-crontab install: installer exited $rc, block written=$(grep -cF "$marker" "$S/home/fake.crontab" 2>/dev/null || echo 0)"
    fail=1
fi

exit "$fail"
