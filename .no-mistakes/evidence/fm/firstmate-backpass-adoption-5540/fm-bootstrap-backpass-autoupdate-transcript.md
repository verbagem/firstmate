== backpass detection (deliverable 1) ==
### backpass-absent
$ bin/fm-bootstrap.sh   ()
MISSING: backpass (install: npm install -g backpass)

### backpass-0.1.15-outdated
$ bin/fm-bootstrap.sh   (FM_FAKE_BACKPASS_VERSION=0.1.15)
MISSING: backpass (install: npm install -g backpass)

### backpass-0.1.16-at-floor
$ bin/fm-bootstrap.sh   (FM_FAKE_BACKPASS_VERSION=0.1.16)
(no output: bootstrap silent = all is well)

### backpass-1.0.0-newer
$ bin/fm-bootstrap.sh   (FM_FAKE_BACKPASS_VERSION=1.0.0)
(no output: bootstrap silent = all is well)

== tool auto-update sweep (opt-in) ==
### autoupdate-flag-absent-default-off
$ bin/fm-bootstrap.sh   (FM_FAKE_NPM_GH_AXI_INSTALLED=0.1.29 FM_FAKE_NPM_GH_AXI_LATEST=0.1.35)
(no output: bootstrap silent = all is well)

### autoupdate-on-outdated-ghaxi-current-backpass
$ bin/fm-bootstrap.sh   (FM_FAKE_NPM_GH_AXI_INSTALLED=0.1.29 FM_FAKE_NPM_GH_AXI_LATEST=0.1.35 FM_FAKE_NPM_BACKPASS_INSTALLED=0.1.16 FM_FAKE_NPM_BACKPASS_LATEST=0.1.16)
BOOTSTRAP_INFO: tool-autoupdate updated gh-axi@0.1.35
[state/.tool-autoupdate-checked written: 1788406734]
[npm calls: install -g gh-axi@0.1.35;]

### autoupdate-same-day-release-default-age-0
$ bin/fm-bootstrap.sh   (FM_FAKE_NPM_BACKPASS_INSTALLED=0.1.16 FM_FAKE_NPM_BACKPASS_LATEST=0.1.17 FM_FAKE_NPM_BACKPASS_PUBLISHED=2026-09-03T03:38:55.000Z)
BOOTSTRAP_INFO: tool-autoupdate updated backpass@0.1.17
[state/.tool-autoupdate-checked written: 1788406736]

### autoupdate-same-day-release-held-with-14d-gate
$ bin/fm-bootstrap.sh   (FM_TOOL_AUTOUPDATE_MIN_AGE_DAYS=14 FM_FAKE_NPM_BACKPASS_INSTALLED=0.1.16 FM_FAKE_NPM_BACKPASS_LATEST=0.1.17 FM_FAKE_NPM_BACKPASS_PUBLISHED=2026-09-03T03:38:55.000Z)
(no output: bootstrap silent = all is well)
[state/.tool-autoupdate-checked written: 1788406739]

### autoupdate-install-fails
$ bin/fm-bootstrap.sh   (FM_FAKE_NPM_INSTALL_FAIL=1 FM_FAKE_NPM_GH_AXI_INSTALLED=0.1.29 FM_FAKE_NPM_GH_AXI_LATEST=0.1.35)
TOOL_AUTOUPDATE: npm install -g gh-axi@0.1.35 failed (was 0.1.29)
[state/.tool-autoupdate-checked written: 1788406741]

### autoupdate-npm-unavailable
$ bin/fm-bootstrap.sh   ()
TOOL_AUTOUPDATE: npm not found on PATH, cannot check for updates
[state/.tool-autoupdate-checked written: 1788406744]

### autoupdate-throttled-checked-1s-ago
$ bin/fm-bootstrap.sh   (FM_FAKE_NPM_GH_AXI_INSTALLED=0.1.29 FM_FAKE_NPM_GH_AXI_LATEST=0.1.35)
(no output: bootstrap silent = all is well)
[state/.tool-autoupdate-checked written: 1788406745]

### autoupdate-missing-package-not-auto-installed
$ bin/fm-bootstrap.sh   (FM_FAKE_NPM_GH_AXI_LATEST=0.1.35)
(no output: bootstrap silent = all is well)
[state/.tool-autoupdate-checked written: 1788406747]

