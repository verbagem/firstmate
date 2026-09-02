# Test evidence: fm-recovery-fork-only (759be68..fee5384)

## Targeted suites (all exit 0)
- tests/fm-fleet-sync.test.sh   (incl. new: registered external path -> registry-name label; unregistered external -> full path label)
- tests/fm-task-delivery.test.sh (fm-project-mode path identity: spaced path=, trailing-token refusal)
- tests/fm-watch-triage.test.sh  (58 ok; paused-monitoring, run-state markers per validation generation)
- tests/fm-crew-state.test.sh, tests/fm-daemon.test.sh

## Manual CLI transcript: fm-project-mode.sh --with-name --path
registry: `- spaced [local-only path=$H/my proj/ect] - ...`
    $ fm-project-mode.sh --with-name --path "$H/my proj/ect"
    spaced local-only off            (exit 0)   <- path with whitespace no longer truncated
registry: `- plain [no-mistakes +yolo path=$H/plain] - ...`
    $ fm-project-mode.sh --with-name --path "$H/plain"
    plain no-mistakes on             (exit 0)
registry: `- bad [no-mistakes path=$H/plain +yolo] - ...`
    $ fm-project-mode.sh --with-name --path "$H/plain"
    error: malformed path identity for bad: path= must be the last annotation token; found trailing token(s) "+yolo" after path= in registry line: - bad [...]
    (exit 2)                                     <- refuses loudly

## Manual CLI transcript: fm-fleet-sync.sh label decision (option B)
registered external  `- pai-agent [local-only path=$H/external/agent]`:
    pai-agent: skipped: local-only project
unregistered external `$H/external/other` (not in registry):
    /var/folders/.../external/other: skipped: no origin remote    <- full disambiguating path kept

## Marker prefix (redundant-generation-prefix-in-marker)
    crew_actionable_run_state_marker_from_state_line "state: done · ... · run-id=01A run-head=aaa111"
    -> single line, identical to the actionable state line (no generation prefix line); lines=1

## AGENTS.md
watcher-internals marker list now: `.hash-* .count-* .stale-* .stale-since-* .paused-* .wedge-escalations-* .run-state-* .seen-* ...` (no `.writing-*`)
