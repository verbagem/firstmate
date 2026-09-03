#!/usr/bin/env bash
set -u
ROOT=$(pwd)
. "$ROOT/tests/lib.sh"
BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin
TMP_ROOT=$(fm_test_tmproot fm-bootstrap-evidence)
export FM_BACKEND_CMUX_BUNDLE_BIN="$TMP_ROOT/no-bundled-cmux"
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_SOCKET_PATH CMUX_TAB_ID CMUX_PANEL_ID 2>/dev/null || true
# reuse the suite's fixture helpers verbatim
eval "$(sed -n '/^make_fake_toolchain()/,/^}/p; /^add_quota_axi()/,/^}/p; /^add_tasks_axi()/,/^}/p; /^add_fake_npm()/,/^}/p' "$ROOT/tests/fm-bootstrap.test.sh")"

scenario() { # name, then env assignments..., with optional pre-hook via $PRE
  local name=$1; shift
  local d="$TMP_ROOT/$name" fb out rc
  mkdir -p "$d/home/config"; printf 'manual\n' > "$d/home/config/backlog-backend"
  fb=$(make_fake_toolchain "$d"); add_fake_npm "$fb"
  [ -z "${PRE:-}" ] || eval "$PRE"
  out=$(env PATH="$fb:$BASE_PATH" FM_HOME="$d/home" FM_ROOT_OVERRIDE="$d/home" FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$@" "$ROOT/bin/fm-bootstrap.sh" 2>&1 | grep -v '^fatal: not a git'); rc=$?
  printf '### %s\n$ bin/fm-bootstrap.sh   (%s)\n' "$name" "$*"
  if [ -n "$out" ]; then printf '%s\n' "$out"; else printf '(no output: bootstrap silent = all is well)\n'; fi
  [ -f "$d/home/state/.tool-autoupdate-checked" ] && printf '[state/.tool-autoupdate-checked written: %s]\n' "$(cat "$d/home/state/.tool-autoupdate-checked")"
  [ -f "$d/npm-install.log" ] && printf '[npm calls: %s]\n' "$(tr '\n' ';' < "$d/npm-install.log")"
  printf '\n'
}

echo "== backpass detection (deliverable 1) =="
PRE='rm -f "$fb/backpass"' scenario backpass-absent
PRE= scenario backpass-0.1.15-outdated FM_FAKE_BACKPASS_VERSION=0.1.15
PRE= scenario backpass-0.1.16-at-floor FM_FAKE_BACKPASS_VERSION=0.1.16
PRE= scenario backpass-1.0.0-newer FM_FAKE_BACKPASS_VERSION=1.0.0

echo "== tool auto-update sweep (opt-in) =="
PRE= scenario autoupdate-flag-absent-default-off FM_FAKE_NPM_GH_AXI_INSTALLED=0.1.29 FM_FAKE_NPM_GH_AXI_LATEST=0.1.35
PRE='printf on\\n > "$d/home/config/tool-autoupdate"; export FM_FAKE_NPM_INSTALL_LOG="$d/npm-install.log"' scenario autoupdate-on-outdated-ghaxi-current-backpass FM_FAKE_NPM_GH_AXI_INSTALLED=0.1.29 FM_FAKE_NPM_GH_AXI_LATEST=0.1.35 FM_FAKE_NPM_BACKPASS_INSTALLED=0.1.16 FM_FAKE_NPM_BACKPASS_LATEST=0.1.16
TODAY=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
PRE='printf on\\n > "$d/home/config/tool-autoupdate"' scenario autoupdate-same-day-release-default-age-0 FM_FAKE_NPM_BACKPASS_INSTALLED=0.1.16 FM_FAKE_NPM_BACKPASS_LATEST=0.1.17 FM_FAKE_NPM_BACKPASS_PUBLISHED="$TODAY"
PRE='printf on\\n > "$d/home/config/tool-autoupdate"' scenario autoupdate-same-day-release-held-with-14d-gate FM_TOOL_AUTOUPDATE_MIN_AGE_DAYS=14 FM_FAKE_NPM_BACKPASS_INSTALLED=0.1.16 FM_FAKE_NPM_BACKPASS_LATEST=0.1.17 FM_FAKE_NPM_BACKPASS_PUBLISHED="$TODAY"
PRE='printf on\\n > "$d/home/config/tool-autoupdate"' scenario autoupdate-install-fails FM_FAKE_NPM_INSTALL_FAIL=1 FM_FAKE_NPM_GH_AXI_INSTALLED=0.1.29 FM_FAKE_NPM_GH_AXI_LATEST=0.1.35
PRE='printf on\\n > "$d/home/config/tool-autoupdate"; rm -f "$fb/npm"' scenario autoupdate-npm-unavailable
PRE='printf on\\n > "$d/home/config/tool-autoupdate"; mkdir -p "$d/home/state"; date +%s > "$d/home/state/.tool-autoupdate-checked"' scenario autoupdate-throttled-checked-1s-ago FM_FAKE_NPM_GH_AXI_INSTALLED=0.1.29 FM_FAKE_NPM_GH_AXI_LATEST=0.1.35
PRE='printf on\\n > "$d/home/config/tool-autoupdate"' scenario autoupdate-missing-package-not-auto-installed FM_FAKE_NPM_GH_AXI_LATEST=0.1.35
rm -rf "$TMP_ROOT"
