#!/usr/bin/env bash
# Operator-facing demo of the recovered canonical project-path resolution in
# bin/fm-project-mode.sh: --path lookups resolve an external project by its
# registered path= annotation and an in-home project by its canonical
# projects/<name> directory, instead of guessing from the directory basename.
set -u
REPO=${1:?usage: project-path-resolution-demo.sh <repo-root>}
HOME_DIR=$(mktemp -d); trap 'rm -rf "$HOME_DIR"' EXIT
mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects/command-center" "$HOME_DIR/projects/firstmate"
mkdir -p "$HOME_DIR/elsewhere/checkout-dir-named-nothing-like-the-project"
cat > "$HOME_DIR/data/projects.md" <<'REG'
# Projects
- command-center [no-mistakes-prod-only +yolo] - the operator home (added 2026-01-01)
- firstmate [no-mistakes] - the fleet supervisor (added 2026-01-01)
- ledger-svc [direct-PR path=HOMEDIR/elsewhere/checkout-dir-named-nothing-like-the-project] - external service (added 2026-02-01)
REG
sed -i.bak "s|HOMEDIR|$HOME_DIR|" "$HOME_DIR/data/projects.md"; rm -f "$HOME_DIR/data/projects.md.bak"

run() {  # <label> <args...>
  local label=$1; shift
  printf '\n$ fm-project-mode.sh %s\n' "$*"
  printf '  # %s\n' "$label"
  FM_HOME="$HOME_DIR" "$REPO/bin/fm-project-mode.sh" "$@" 2>&1 | sed 's/^/  /'
}

echo "registry (data/projects.md):"; sed 's/^/  /' "$HOME_DIR/data/projects.md"

run "external project resolved by its registered path= annotation, NOT the basename" \
  --with-name --path "$HOME_DIR/elsewhere/checkout-dir-named-nothing-like-the-project"
run "in-home project resolved by its canonical projects/<name> path" \
  --with-name --path "$HOME_DIR/projects/firstmate"
run "conditional policy maps to its most rigorous leg for mechanical callers" \
  --with-name --path "$HOME_DIR/projects/command-center"
run "...and --raw shows the conditional policy itself, unmapped" \
  --raw --with-name --path "$HOME_DIR/projects/command-center"
run "an unregistered path keeps the safe default posture and warns, never silently drops the gate" \
  --with-name --path "$HOME_DIR/elsewhere/not-registered"
echo
