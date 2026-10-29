#!/usr/bin/env bash
# Resolve a project's REGISTERED delivery posture from the data/projects.md registry.
# Default usage prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
# --branch-prefix instead prints one value: the project's registered ship-branch
# prefix, "fm/" when the project registers none, is unregistered, or the registry
# is absent, so every existing installation keeps its current "fm/<task-id>"
# branch names unchanged.
# With --forge it prints one word instead: the project's registered forge,
# none|gerrit|forgejo|external. The forge is asked for explicitly, so the
# default output stays the same two words for every project, bound or not.
# With --with-name the default (or --raw) output is prefixed by the resolved
# registry name, "<name> <mode> <yolo>"; the name may contain spaces, so read
# the mode and yolo as the LAST two words.
# With --path <project-path> the project is resolved by canonical directory
# instead of by name (see "Path lookups" below), so a project registered outside
# projects/ gets its real posture and two projects sharing a basename cannot pick
# each other's entry.
# --policy-snapshot must be combined with --path. It reads the registry once and
# prints the selected row's name, raw mode, effective yolo, forge, and branch
# prefix as six key=value lines (the sixth names path, fallback, or default
# resolution), so a mechanical caller can bind every policy from one row version.
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode,
# yolo, and ship-branch prefix are resolved by firstmate at intake and passed
# explicitly to bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-promote.sh (AGENTS.md
# section 7; bin/fm-brief.sh's own header owns the --branch-prefix flag it accepts).
# The consumers are bin/fm-fleet-sync.sh (skip local-only clones),
# bin/fm-home-seed.sh and bin/fm-remote-home-seed.sh (refuse local-only seeding,
# run no-mistakes init), bin/fm-spawn.sh's advisory registry-deviation notice,
# and --forge for bin/fm-spawn.sh's forge agreement and yolo refusal and for
# bin/fm-promote.sh, which takes the forge binding from here because it is a
# project fact rather than a task choice.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                                 -> no-mistakes off fm/  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)                        -> <mode> off fm/
#   - <name> [<mode> +yolo] - <desc> (added <date>)                  -> <mode> on fm/
#   - <name> [<mode> +yolo branch=<prefix>] - <desc> (added <date>)  -> <mode> <yolo> <prefix>
#   - <name> [<mode> forge=gerrit] - <desc> (added <date>)           -> <mode> off, --forge gerrit
#   - <name> [<mode> forge=forgejo] - <desc> (added <date>)          -> <mode> <yolo>, --forge forgejo
#   - <name> [direct-PR forge=external] - <desc> (added <date>)      -> direct-PR off, --forge external
#   - <name> [<mode> path=/absolute/project] - <desc> (added <date>) -> the entry's identity is that path
#   path= runs to the closing ] so the path may contain spaces; it must be the last
#   token (a mode, +yolo, or key=value token written after it is refused), appears
#   once, and is absolute. It is never read as a mode, +yolo, branch, or forge token.
#   <name> may contain spaces; it ends at the literal " [" or " - " that follows it.
#   Bracket tokens are order-independent: +yolo, branch=<prefix>, and forge=<value>
#   are recognized by their own shape wherever they appear, and whichever token is
#   left over is the mode. <prefix> must not contain a space; an empty override
#   ("branch=") resolves to "" for a bare "<task-id>" ship branch instead of the
#   legacy "fm/<task-id>".
#
# Registered modes:
#   no-mistakes            full pipeline -> PR -> configured merge authority (default)
#   direct-PR              push + PR via gh-axi, no pipeline
#   local-only             local branch, no remote/PR, guarded local merge
#   no-mistakes-prod-only  a conditional policy, not a task mode: firstmate
#                          classifies each task's surface at intake (the
#                          project-management skill owns that classification).
#                          Mechanical output maps it to its most rigorous leg,
#                          no-mistakes, so sync, seeding, and init treat such a
#                          project as the remote-backed pipeline project it is.
# yolo (orthogonal) = merge authority only: when on, firstmate merges green,
#   in-scope work itself (AGENTS.md section 7).
# branch=<prefix> (orthogonal) = overrides the "fm/" ship-branch prefix so a
#   project's branch and PR do not read as firstmate-authored, e.g. for a
#   third-party repo that does not use this tooling. Query it with
#   --branch-prefix; it never appears in the default "<mode> <yolo>" output, so
#   existing mechanical callers are unaffected by its presence.
# forge (orthogonal, and orthogonal to yolo too) = which forge the project's
#   remote actually is, never inferred from mode, remote name, host, or protocol.
#   `none` means a forge whose pull requests and checks no-mistakes already
#   drives, `gerrit` means a Gerrit server: no pull requests, so the worker
#   publishes a change with gerrit-axi instead, and `forgejo` means a Forgejo or
#   Gitea server, whose pull requests the worker handles with tea rather than
#   gh-axi, and `external` means the project's reviews are created by a review
#   tool that uploads its own snapshot of the worker's local commits: the
#   worker never needs to push a branch, and must never push a task branch to
#   the project's shared origin. Firstmate cannot observe, approve, or merge
#   such a review, so that rail always escalates (bin/fm-dod-lib.sh owns what
#   each changes for a worker in each publishing mode;
#   docs/forgejo-tea-integration.md holds the tea evidence and
#   docs/external-review-forge.md the external design).
#   The binding is EXPLICIT because a provider family must never be guessed;
#   bin/fm-forge-detect.sh proposes gerrit from a protocol fact at project-add
#   intake, forgejo has no such fact and is proposed from the captain's own
#   account of the host, external is never detected or proposed because no
#   protocol fact identifies a snapshot-uploading review tool, and the captain's
#   confirmation is what this record holds.
#   A forge describes what a mode publishes, so it composes with no-mistakes and
#   direct-PR and is REFUSED on local-only, which publishes nothing: that mode
#   lands by fast-forwarding local main, which on a review-server project
#   advances it with content the server has never seen
#   (docs/gerrit-forge-integration.md section 3).
#
# A registered `forge=gerrit` project reports yolo=off with an explicit stderr
# refusal, on the captain's decision of 2026-09-15: a Gerrit Code-Review+2 is a
# positive attributed claim that a named human approved, read by colleagues and
# by any audit, and firstmate must not manufacture one. A registered
# `forge=external` project reports yolo=off the same way, because firstmate can
# neither observe nor perform the review tool's approval or merge.
#
# --raw prints the registered mode annotation unmapped, so a caller that must
# tell a conditional policy apart from a flat mode sees "no-mistakes-prod-only"
# itself. Not combined with --branch-prefix, which has no conditional-policy leg.
#
# Path lookups (--path) match structured identities only: one path= token inside
# the registry annotation, or else the canonical in-home <projects>/<name> path.
# They never parse descriptions, backticks, or prose such as "at <path>". An
# unknown path keeps the protective default ("no-mistakes off", "fm/", or "none")
# and warns; a malformed or ambiguous registered identity is refused (exit 2).
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" (or
# "fm/" under --branch-prefix) and warns to stderr, so a typo never silently
# drops the gate. Other annotation tokens are ignored, as they always were, keyed
# ones included: a `<key>=<value>` token whose key is neither exactly `forge` nor
# `branch` resolves as it did before the forge existed, and in the mode slot it
# is read as an unknown mode. A key one or two edits from `forge` (such as
# `forg=` or `Forge=`) is still ignored, with one stderr warning naming the token
# and the forge=gerrit, forge=forgejo, and forge=external spellings. The one
# refusal is a malformed forge binding - a `forge=` token whose value is empty or outside the
# closed set - which is REFUSED in the default and --forge output forms: nothing
# on stdout, exit status 3, the token named. Resolving it to "no registered
# forge" would hand a Gerrit project the pull-request contract the binding
# exists to prevent.
# local-only with a forge is refused the same way. --branch-prefix does not make
# that check: it answers only the registered prefix, and a prefix is orthogonal
# to the forge binding, so it prints even when the forge token is malformed;
# every path that reads the forge binding (default, --forge, and spawn's
# forge-agreement check) still refuses.
# Usage: fm-project-mode.sh [--raw|--branch-prefix|--forge|--policy-snapshot] [--with-name] [--path <project-path>] [<project-name>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
REG="$DATA/projects.md"
RAW=0
BRANCH_PREFIX_QUERY=0
WANT_FORGE=0
WITH_NAME=0
POLICY_SNAPSHOT=0
PATH_ARG=
NAME=
USAGE="usage: fm-project-mode.sh [--raw|--branch-prefix|--forge|--policy-snapshot] [--with-name] [--path <project-path>] [<project-name>]"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --raw) RAW=1 ;;
    --branch-prefix) BRANCH_PREFIX_QUERY=1 ;;
    --forge) WANT_FORGE=1 ;;
    --policy-snapshot) POLICY_SNAPSHOT=1 ;;
    --with-name) WITH_NAME=1 ;;
    --path)
      [ "$#" -ge 2 ] || { echo "$USAGE" >&2; exit 2; }
      PATH_ARG=$2
      shift
      ;;
    --path=*) PATH_ARG=${1#--path=} ;;
    --*) echo "$USAGE" >&2; exit 2 ;;
    *)
      [ -z "$NAME" ] || { echo "$USAGE" >&2; exit 2; }
      NAME=$1
      ;;
  esac
  shift
done
[ -n "$NAME" ] || [ -n "$PATH_ARG" ] || { echo "$USAGE" >&2; exit 2; }
[ -z "$NAME" ] || [ -z "$PATH_ARG" ] || { echo "$USAGE" >&2; exit 2; }
[ "$POLICY_SNAPSHOT" -eq 0 ] || { [ -n "$PATH_ARG" ] && [ "$RAW" -eq 0 ] && [ "$BRANCH_PREFIX_QUERY" -eq 0 ] && [ "$WANT_FORGE" -eq 0 ] && [ "$WITH_NAME" -eq 0 ]; } \
  || { echo "$USAGE" >&2; exit 2; }

emit_default() {  # <name>: the protective default in whichever form was asked for
  if [ "$POLICY_SNAPSHOT" -eq 1 ]; then
    printf 'name=%s\nmode=no-mistakes\nyolo=off\nforge=none\nbranch-prefix=fm/\nresolution=default\n' "$1"
  elif [ "$BRANCH_PREFIX_QUERY" -eq 1 ]; then
    echo "fm/"
  elif [ "$WANT_FORGE" -eq 1 ]; then echo none
  elif [ "$WITH_NAME" -eq 1 ]; then echo "$1 no-mistakes off"
  else echo "no-mistakes off"; fi
}

normalize_path() {  # <path>: physical path of a directory, else the absolute spelling
  local p=$1
  [ -n "$p" ] || return 1
  if [ -d "$p" ]; then ( cd "$p" && pwd -P ); return; fi
  case "$p" in
    /*) ;;
    *) p="$(pwd -P)/$p" ;;
  esac
  while [ "$p" != "/" ] && [ "${p%/}" != "$p" ]; do p=${p%/}; done
  printf '%s\n' "$p"
}

# Path lookup resolves the registry NAME (and its line, so duplicate names cannot
# cross) before the ordinary name-based parse below.
SEL_LINE=0
SELECTED_ROW=
SNAPSHOT_RESOLUTION=path
if [ -n "$PATH_ARG" ]; then
  NAME=$(basename -- "$PATH_ARG")
  if [ ! -f "$REG" ]; then
    echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off" >&2
    emit_default "$NAME"
    exit 0
  fi
  target=$(normalize_path "$PATH_ARG") || target=
  case "$target" in
    /*) ;;
    *) echo "error: --path must be an absolute path or an existing directory: $PATH_ARG" >&2; exit 2 ;;
  esac
  idents=$(awk -v projects="$PROJECTS" '
    function malformed(msg, candidate) { print "err", NR "\t" nm "\t" candidate "\t" msg }
    substr($0, 1, 2) != "- " { next }
    {
      print "row", NR "\t" $0;
      rest = substr($0, 3);
      i = index(rest, " [");
      j = index(rest, " - ");
      if (i > 0 && (j == 0 || i < j)) { nm = substr(rest, 1, i - 1); ann = substr(rest, i + 2); c = index(ann, "]"); ann = c ? substr(ann, 1, c - 1) : "" }
      else if (j > 0) { nm = substr(rest, 1, j - 1); ann = "" }
      else { nm = rest; ann = "" }
      cand = projects "/" nm;
      p = index(ann, "path=");
      if (p > 0 && (p == 1 || substr(ann, p - 1, 1) == " ")) {
        pv = substr(ann, p + 5);
        q = index(pv, " path=");
        if (q > 0) {
          cand = substr(pv, 1, q - 1);
          malformed("malformed path identity for " nm ": multiple path= tokens", cand);
          next;
        }
        sub(/[[:space:]]+$/, "", pv);
        nt = split(pv, tk, " ");
        for (t = 2; t <= nt; t++)
          if (tk[t] ~ /^\+/ || tk[t] ~ /=/ || tk[t] ~ /^(no-mistakes|direct-PR|local-only|no-mistakes-prod-only)$/) {
            marker = " " tk[t]; q = index(pv, marker); cand = substr(pv, 1, q - 1);
            malformed("malformed path identity for " nm ": path= must be the last annotation token; found trailing token(s) \"" tk[t] "\" after path= in registry line: " $0, cand);
            next;
          }
        if (substr(pv, 1, 1) != "/") { malformed("malformed path identity for " nm ": path= must be an absolute path", pv); next }
        cand = pv;
      }
      print "ident", NR "\t" nm "\t" cand "\t" $0
    }
  ' "$REG")
  matches=0
  match_names=
  captured_rows=
  path_error=
  selected_path_error=
  while IFS= read -r row; do
    case "$row" in
      "row "*)
        row=${row#row }; row=${row#*$'\t'}
        captured_rows="$captured_rows$row"$'\n'
        ;;
      "err "*)
        row=${row#err }; r_ln=${row%%$'\t'*}; row=${row#*$'\t'}
        r_name=${row%%$'\t'*}; row=${row#*$'\t'}
        r_cand=${row%%$'\t'*}; r_error=${row#*$'\t'}
        path_error=${path_error:-$r_error}
        if [ -n "$r_cand" ] && [ "$(normalize_path "$r_cand")" = "$target" ]; then
          selected_path_error=$r_error
        fi
        ;;
      "ident "*)
        row=${row#ident }
        r_ln=${row%%$'\t'*}; row=${row#*$'\t'}
        r_name=${row%%$'\t'*}; row=${row#*$'\t'}
        r_cand=${row%%$'\t'*}; r_row=${row#*$'\t'}
        if [ "$(normalize_path "$r_cand")" = "$target" ]; then
          matches=$((matches + 1))
          SEL_LINE=$r_ln
          NAME=$r_name
          SELECTED_ROW=$r_row
          match_names="$match_names${match_names:+, }$r_name"
        fi
        ;;
    esac
  done <<PATHROWS
$idents
PATHROWS
  if [ -n "$selected_path_error" ]; then
    echo "error: $selected_path_error" >&2
    exit 2
  fi
  if [ -n "$path_error" ]; then
    if [ "$POLICY_SNAPSHOT" -eq 0 ]; then
      echo "error: $path_error" >&2
      exit 2
    fi
    echo "error: $path_error" >&2
    NAME=$(basename -- "$PATH_ARG")
    SEL_LINE=0
    SELECTED_ROW=
    SNAPSHOT_RESOLUTION=fallback
  fi
  if [ -z "$path_error" ] && [ "$matches" -eq 0 ]; then
    NAME=$(basename -- "$PATH_ARG")
    echo "warn: no project registered for path \"$PATH_ARG\"; defaulting $NAME to no-mistakes off" >&2
    SNAPSHOT_RESOLUTION=default
    emit_default "$NAME"
    exit 0
  fi
  if [ -z "$path_error" ] && [ "$matches" -gt 1 ]; then
    echo "error: ambiguous path identity \"$PATH_ARG\" matches multiple projects: $match_names" >&2
    exit 2
  fi
fi

if [ ! -f "$REG" ]; then
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off" >&2
  emit_default "$NAME"
  exit 0
fi

# awk emits one "near <token>" line per keyed token whose key is a near miss of
# `forge`, then "posture <mode> <yolo> <branch-prefix> <forge>" (branch-prefix is
# the raw prefix, defaulting to "fm/"; forge is `none` or the whole `forge=<value>`
# token, so an empty value survives the split), or nothing if the project is
# absent. Every other token beside the mode is ignored, exactly as before either
# annotation existed.
parse_policy() {  # <selected-line> [<registry-file>]
  local selected_line=$1
  shift
  awk -v n="$NAME" -v sel="$selected_line" '
  function dist(x, y,   i, j, lx, ly, d, c, v) {
    lx = length(x); ly = length(y);
    for (i=0; i<=lx; i++) d[i,0] = i;
    for (j=0; j<=ly; j++) d[0,j] = j;
    for (i=1; i<=lx; i++) for (j=1; j<=ly; j++) {
      c = (substr(x,i,1) == substr(y,j,1)) ? 0 : 1;
      v = d[i-1,j] + 1;
      if (d[i,j-1] + 1 < v) v = d[i,j-1] + 1;
      if (d[i-1,j-1] + c < v) v = d[i-1,j-1] + c;
      d[i,j] = v;
    }
    return d[lx,ly];
  }
  {
    # Exact whole-name match on the raw line text (never a regex, so a name
    # containing dots or brackets is compared literally): the line must start
    # with "- " n, and the text right after the name must be empty, or start
    # with " [" or " - ", so a name that is a leading prefix of a longer
    # registered name does not match that longer row.
    if (sel + 0 > 0 && NR != sel + 0) next
    prefix = "- " n; plen = length(prefix);
    if (substr($0, 1, plen) != prefix) next
    after = substr($0, plen + 1);
    if (after != "" && substr(after, 1, 2) != " [" && substr(after, 1, 3) != " - ") next
    mode="no-mistakes"; yolo="off"; branch="fm/"; forge="none";
    if (substr(after, 1, 2) == " [") {
      s="";
      nk = split(after, rest, " ");
      for (i=1; i<=nk; i++) { s = s (s==""?"":" ") rest[i]; if (rest[i] ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      # Tokens are order-independent: +yolo, branch=<prefix>, and forge=<value>
      # are recognized by their own shape wherever they appear, keyed tokens
      # that are neither are ignored (with a near-miss warning for the forge
      # spelling), and the first token left over is the mode.
      mode_set = 0
      for (j=1; j<=k; j++) {
        # path= is an identity, never a mode; it must be last and may hold spaces.
        if (a[j] ~ /^path=/) break
        if (a[j]=="+yolo") { yolo="on"; continue }
        if (a[j] ~ /^branch=/) { branch = substr(a[j], 8); continue }
        if (a[j] ~ /^forge=/) { forge = a[j]; continue }
        if (a[j] ~ /^[^=]+=/) {
          key = substr(a[j], 1, index(a[j], "=") - 1);
          e = dist(key, "forge");
          if (e >= 1 && e <= 2) print "near", a[j];
          if (mode_set == 0) { mode = a[j]; mode_set = 1 }
          continue
        }
        if (a[j] != "" && mode_set == 0) { mode = a[j]; mode_set = 1 }
      }
    }
    # branch is printed LAST: an empty branch= override must survive as an
    # empty final field, which only holds when nothing follows it.
    print "posture", mode, yolo, forge, branch; exit
  }
' "$@"
}
if [ -n "$PATH_ARG" ]; then
  [ -z "$SELECTED_ROW" ] || captured_rows=$SELECTED_ROW
  parsed=$(printf '%s\n' "$captured_rows" | parse_policy 0)
else
  parsed=$(parse_policy "$SEL_LINE" "$REG")
fi

if [ -z "$parsed" ]; then
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
  emit_default "$NAME"
  exit 0
fi

posture=
while IFS=' ' read -r kind rest; do
  case "$kind" in
    near) echo "warn: ignoring \"$rest\" registered for $NAME in $REG; it is not a forge binding, and the forge binding is spelled forge=gerrit, forge=forgejo, or forge=external" >&2 ;;
    posture) posture=$rest ;;
  esac
done <<EOF
$parsed
EOF
while IFS=' ' read -r m y f b; do
  mode=$m; yolo=$y; rest_forge=$f; branch=$b
done <<EOF
$posture
EOF
forge=${rest_forge:-none}
case "$mode" in
  no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off" >&2; mode=no-mistakes; yolo=off; branch=fm/ ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
if [ "$BRANCH_PREFIX_QUERY" -eq 1 ]; then
  echo "$branch"
  exit 0
fi

case "$forge" in
  none|forge=gerrit|forge=forgejo|forge=external) forge=${forge#forge=} ;;
  forge=)
    echo "refused: empty forge binding \"forge=\" registered for $NAME in $REG; the accepted values are forge=gerrit, forge=forgejo, and forge=external, or no forge token at all for a forge whose pull requests no-mistakes already drives; correct the registry entry" >&2
    exit 3 ;;
  *)
    echo "refused: unknown forge \"${forge#forge=}\" registered for $NAME in $REG; the accepted values are forge=gerrit, forge=forgejo, and forge=external, or no forge token at all for a forge whose pull requests no-mistakes already drives; correct the registry entry" >&2
    exit 3 ;;
esac
if [ "$forge" != none ] && [ "$mode" = local-only ]; then
  echo "refused: $NAME is registered local-only with forge=$forge in $REG; local-only publishes nothing, so a forge has no meaning there, and its landing would fast-forward local main with content the review server has never seen; register no-mistakes or direct-PR to publish through the forge, or drop the forge token to keep the project local" >&2
  exit 3
fi
if [ "$WANT_FORGE" -eq 1 ]; then
  echo "$forge"
  exit 0
fi
if [ "$forge" = gerrit ] && [ "$yolo" = on ]; then
  echo "refused: +yolo is registered for $NAME but yolo is inactive for forge=gerrit, so this reports yolo=off: a Gerrit Code-Review+2 is a positive attributed claim that a named human approved, and firstmate must not manufacture one (captain's decision 2026-09-15)" >&2
  yolo=off
fi
if [ "$forge" = external ] && [ "$yolo" = on ]; then
  echo "refused: +yolo is registered for $NAME but yolo is inactive for forge=external, so this reports yolo=off: firstmate can neither observe nor perform the review tool's approval or merge, so every review escalates" >&2
  yolo=off
fi
if [ "$POLICY_SNAPSHOT" -eq 1 ]; then
  printf 'name=%s\nmode=%s\nyolo=%s\nforge=%s\nbranch-prefix=%s\nresolution=%s\n' \
    "$NAME" "$mode" "$yolo" "$forge" "$branch" "$SNAPSHOT_RESOLUTION"
  exit 0
fi
# A conditional policy is not a task mode. Mechanical callers get its most
# rigorous leg; --raw callers get the annotation itself (see the header).
if [ "$RAW" -eq 0 ] && [ "$mode" = no-mistakes-prod-only ]; then
  mode=no-mistakes
fi
if [ "$WITH_NAME" -eq 1 ]; then echo "$NAME $mode $yolo"; else echo "$mode $yolo"; fi
