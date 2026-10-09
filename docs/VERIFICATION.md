# Verification boundaries

Fixture tests check six solar phases, independent solar reference times, DST,
midnight, polar behavior, mapping readiness, native graph validation, scoped
preservation, conflicting changes and conditional restoration. They never change
live wallpaper settings or prove native display behavior.

The opt-in native smoke test checks selector readback, native aerial movie
activation, and conditional restoration on the running OS build. A successful
smoke report does not automatically enable unattended rotation. Visual
confirmation is separate and invalidated when the OS build changes.

Required observed checks include all connected displays, representative desktop
Spaces, the matching animated screen saver, ordinary restart, and manual edits.
Login registration and location authorization must be checked using the actual
packaged build. Permission continuity across app updates depends on signing.

Release-build idle measurements exclude Apple's pre-existing video renderer.
Targets: near-zero idle CPU and less than 50 MiB resident app memory with Settings
closed. Record actual results, not estimates.

## Evidence for this development run

Development host: Apple Silicon, macOS 27.0.1 (26A434), Swift 6.4 Command Line
Tools. Evidence recorded 2026-10-08.

| Check | Result |
| --- | --- |
| Solar fixtures | Nine tests passed, including seven independently published USNO Boston sunrise/sunset pairs within two minutes. |
| Verification/recovery policy fixtures | Thirteen tests passed, including failed rechecks, OS/store changes, stale approvals and recovery provenance. |
| Private persistence fixtures | Three tests passed for interrupted-apply baseline preservation, private file permissions and corrupt/unknown pending records. |
| Native adapter/catalog fixtures | Seventeen tests passed, covering preservation, racing writers, recovery after committed writes, post-reload restoration, metadata/permissions and missing downloads. |
| Release packaging | Full app and bundled diagnostics built; plist lint and strict ad-hoc signature verification passed. |
| Read-only app launch | Passed; four animated Golden Gate previews were loaded. Offscreen AppKit capture does not reliably render glass control labels, so it is limited layout evidence. |
| Native round trip | Passed: Night then Day, 29 selectors agreed, native aerial extension opened each selected movie, original selector values restored with no skipped values. |
| First idle sample | Read-only release app, Settings hidden: four samples five seconds apart showed 0.0% CPU and 55,728–55,888 KiB RSS (54.4–54.6 MiB). This exceeded the memory target. |
| Final normal idle sample | After lazy location initialization: 0.0% CPU in four samples five seconds apart; 55,728–56,048 KiB RSS (54.4–54.7 MiB). |
| Final after Settings closed | 0.0% CPU in four samples five seconds apart; 93,024–93,456 KiB RSS (90.8–91.3 MiB). Private-state fingerprints were unchanged. |

The under-50-MiB target remains unmet. These bounded samples are not a long-term
leak test or a measurement of Apple’s separate renderer.

No visual verification marker was created. Human observation of every monitor,
representative Spaces and matching animated screen saver remains pending.
Ordinary restart, location authorization, login registration, and permission
continuity after app replacement also remain pending. Fixture tests cover
wake/travel/DST decisions and external edits; they do not prove those native
lifecycle effects.

The app remains disabled until its native smoke check and the user's held visual
verification both succeed for this OS build and schema. A successful reviewer
score is a source-quality gate, not a claim that pending native checks passed.

## Reviewer gate

Snark Scalesnout reviews without programming. Weighted score: correctness 2.5,
settings safety 2.5, lightweight maintainability 1.5, evidence 1.5, UI 1.0,
update handling 1.0. Maximum four scored passes; an 8/10 requires no blocking
findings. Numerical scores never substitute for missing runtime evidence.

| Scored review | Result | Follow-up |
| --- | --- | --- |
| 1 | 7.5/10, blocked | Add durable startup recovery for ordinary rotation writes; measure memory after deferring location initialization. |
| 2 | 8.3/10, no blocking findings | Approved the gated preview. Memory target, human native checks and production-orchestration coverage remain limitations. |
