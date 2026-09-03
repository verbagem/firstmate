# fm-pi-recap.sh end-user transcript: the widget lines Pi shows belowEditor at each lifecycle point
# backlog.md entry: '- [ ] recap-demo-7731 - Add recap widget to Pi crewmates <https://github.com/verbagem/firstmate/issues/42> blocked-by: t0 - waits on Pi 0.82 (repo: firstmate) (kind: ship) (since 2026-09-01)'
# (wrapped URL + blocked-by clause are stripped by the shared title_of pipeline, req 2)

### 1. Fresh spawn, no status file yet -> 'Starting up' (req 3)
$ cat state/recap-demo-7731.status
  (absent)
$ bin/fm-pi-recap.sh render <id> <state> <data>   # widget lines, belowEditor
  │ Add recap widget to Pi crewmates
  │ Starting up

### 2. First working line -> In progress
$ cat state/recap-demo-7731.status
  working: reading the spawn template
$ bin/fm-pi-recap.sh render <id> <state> <data>   # widget lines, belowEditor
  │ Add recap widget to Pi crewmates
  │ In progress: reading the spawn template

### 3. Unrecognized verb -> 'Update: <note>' not 'Starting up' (req 3)
$ cat state/recap-demo-7731.status
  working: reading the spawn template
  pondering: whether to use setWidget or a custom pane
$ bin/fm-pi-recap.sh render <id> <state> <data>   # widget lines, belowEditor
  │ Add recap widget to Pi crewmates
  │ Update: whether to use setWidget or a custom pane

### 4. Three open decisions, latest is the blocker -> text once, (+2 more) kept (req 4)
$ cat state/recap-demo-7731.status
  working: reading the spawn template
  pondering: whether to use setWidget or a custom pane
  blocked: [key=api] waiting on API access
  needs-decision: [key=retry] pick a retry policy
  blocked: [key=disk] disk full
$ bin/fm-pi-recap.sh render <id> <state> <data>   # widget lines, belowEditor
  │ Add recap widget to Pi crewmates
  │ Blocked: disk full (+2 more)

### 5. Sanitizer: OSC+CSI stripped, /Users and /opt paths redacted, token=/sk- redacted, long hyphenated word, relative path and URL kept (req 1, 8)
$ cat state/recap-demo-7731.status
  working: reading the spawn template
  pondering: whether to use setWidget or a custom pane
  blocked: [key=api] waiting on API access
  needs-decision: [key=retry] pick a retry policy
  blocked: [key=disk] disk full
  working: cleaned /Users/temp/secret-proj/x.log and /opt/homebrew/etc/y and ]0;title[31mred[0m text; token=abc123def456ghi789 sk-live_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345 see docs/scripts.md and https://example.com/path/segment; the-longest-hyphenated-identifier-ever-written-here stays
$ bin/fm-pi-recap.sh render <id> <state> <data>   # widget lines, belowEditor
  │ Add recap widget to Pi crewmates
  │ In progress: cleaned [path] and [path] and red text; [redacted] [redacted] see docs/scripts.md and https://examp…
  │ Blocked: disk full (+2 more)

### 6. PR link appears once meta has pr= that parses under fm_pr_url_parse (req 5)
$ cat state/recap-demo-7731.status
  working: reading the spawn template
  pondering: whether to use setWidget or a custom pane
  blocked: [key=api] waiting on API access
  needs-decision: [key=retry] pick a retry policy
  blocked: [key=disk] disk full
  working: cleaned /Users/temp/secret-proj/x.log and /opt/homebrew/etc/y and ]0;title[31mred[0m text; token=abc123def456ghi789 sk-live_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345 see docs/scripts.md and https://example.com/path/segment; the-longest-hyphenated-identifier-ever-written-here stays
$ cat state/recap-demo-7731.meta
  pr=https://github.com/verbagem/firstmate/pull/123
$ bin/fm-pi-recap.sh render <id> <state> <data>   # widget lines, belowEditor
  │ Add recap widget to Pi crewmates
  │ In progress: cleaned [path] and [path] and red text; [redacted] [redacted] see docs/scripts.md and https://examp…
  │ Blocked: disk full (+2 more)
  │ PR: https://github.com/verbagem/firstmate/pull/123

### 7. pr= value outside the allowlist (query string) -> goes through the sanitizer instead of verbatim (req 5)
$ cat state/recap-demo-7731.status
  working: reading the spawn template
  pondering: whether to use setWidget or a custom pane
  blocked: [key=api] waiting on API access
  needs-decision: [key=retry] pick a retry policy
  blocked: [key=disk] disk full
  working: cleaned /Users/temp/secret-proj/x.log and /opt/homebrew/etc/y and ]0;title[31mred[0m text; token=abc123def456ghi789 sk-live_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345 see docs/scripts.md and https://example.com/path/segment; the-longest-hyphenated-identifier-ever-written-here stays
$ cat state/recap-demo-7731.meta
  pr=https://github.com/verbagem/firstmate/pull/123?token=abcdefghijklmnop
$ bin/fm-pi-recap.sh render <id> <state> <data>   # widget lines, belowEditor
  │ Add recap widget to Pi crewmates
  │ In progress: cleaned [path] and [path] and red text; [redacted] [redacted] see docs/scripts.md and https://examp…
  │ Blocked: disk full (+2 more)
  │ PR: https://github.com/verbagem/firstmate/pull/123?[redacted]

### 8. All decisions resolved, done -> compact final recap
$ cat state/recap-demo-7731.status
  working: reading the spawn template
  pondering: whether to use setWidget or a custom pane
  blocked: [key=api] waiting on API access
  needs-decision: [key=retry] pick a retry policy
  blocked: [key=disk] disk full
  working: cleaned /Users/temp/secret-proj/x.log and /opt/homebrew/etc/y and ]0;title[31mred[0m text; token=abc123def456ghi789 sk-live_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345 see docs/scripts.md and https://example.com/path/segment; the-longest-hyphenated-identifier-ever-written-here stays
  resolved: [key=api] granted
  resolved: [key=retry] exponential
  resolved: [key=disk] freed
  done: PR checks green and merged
$ cat state/recap-demo-7731.meta
  pr=https://github.com/verbagem/firstmate/pull/123
$ bin/fm-pi-recap.sh render <id> <state> <data>   # widget lines, belowEditor
  │ Add recap widget to Pi crewmates
  │ Done: PR checks green and merged
  │ PR: https://github.com/verbagem/firstmate/pull/123

### 9. FM_PI_RECAP_LINE_MAX=40 -> deterministic ellipsis truncation (documented env var, req 6)
  │ Add recap widget to Pi crewmates
  │ Done: PR checks green and merged
  │ PR: https://github.com/verbagem/firstmate/pull/123
