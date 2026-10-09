# Verification boundaries

Fixture tests check six solar phases, independent solar reference times, DST,
midnight, polar behavior, mapping readiness, native graph validation, scoped
preservation, conflicting changes and conditional restoration. They never change
live wallpaper settings or prove native display behavior.

The opt-in native smoke test checks selector readback, native aerial movie
activation, and conditional restoration on the running OS build. A successful
smoke report permits scheduling only after the user explicitly enables Rotation.
The check is repeated on explicit Enable after the OS build changes. A passing
report cannot prove that every display or animated screen saver looks correct.

Required observed checks include all connected displays, representative desktop
Spaces, the matching animated screen saver, ordinary restart, and manual edits.
Login registration and location authorization must be checked using the actual
packaged build. Permission continuity across app updates depends on signing.

Release-build idle measurements exclude Apple's pre-existing video renderer.
Targets: near-zero idle CPU and less than 50 MiB resident app memory with Settings
closed. Record actual results, not estimates.

## Initial 0.1 development evidence

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

Version 0.1 used a separate held visual-confirmation gate. The user subsequently
confirmed the working wallpaper rotation. Version 0.2 removes that manual button
and runs compatibility checks on explicit Enable. The earlier measurements and
pending observations above describe the initial development run; they are not
claims of fresh verification for version 0.2. Settings may use more memory while
open, with its preview views released on close.

## Reviewer gate

Snark Scalesnout reviews without programming. Weighted score: correctness 2.5,
settings safety 2.5, lightweight maintainability 1.5, evidence 1.5, UI 1.0,
update handling 1.0. Maximum four scored passes; an 8/10 requires no blocking
findings. Numerical scores never substitute for missing runtime evidence.

| Scored review | Result | Follow-up |
| --- | --- | --- |
| 1 | 7.5/10, blocked | Add durable startup recovery for ordinary rotation writes; measure memory after deferring location initialization. |
| 2 | 8.3/10, no blocking findings | Approved the gated preview. Memory target, human native checks and production-orchestration coverage remain limitations. |

## Settings update 0.2

The critic viewed private screenshots of the actual rendered windows, then the
active installed app. Visual interface score improved from 6.5/10 to 8.5/10 with
no material visual defects. This visual score is separate from the earlier
weighted implementation score. The selected-scene border uses the system accent.
The final clarity adjustment labels tomorrow’s next transition explicitly.

Local verification: 51 fixtures passed (7 private persistence, 22 core/policy,
22 native adapter/catalog/lease). Release app and bundled helper built, plist lint
and strict ad-hoc signature checks passed. Nine added fixtures cover automatic
compatibility report validation and durable helper-stage/lease recovery. These
fixtures do not substitute for a newly observed live helper interruption test.

The installed app was gracefully replaced at its existing path. Rotation remained
enabled; selected set, saved location and ownership receipt were unchanged. The
native wallpaper-store SHA-256 was unchanged and no pending operations remained.
The actual Settings switch still reported Start at Login enabled. Location
permission guidance appeared after replacement; the saved-location fallback
remained active. Permission continuity with an ad-hoc signer is not guaranteed.

The user confirmed the existing wallpaper rotation works. This update does not
claim fresh observation of every Space, screen saver, ordinary OS restart, or a
morning transition. Screenshots, local coordinates and media remain private.

Four final normal-release samples five seconds apart, Settings never opened this
launch: 0.0% CPU; 37,280–53,872 KiB RSS (36.4–52.6 MiB). A separate read-only
release run opened Settings then closed it automatically: 0.0% CPU in four
samples; 90,720–95,088 KiB RSS (88.6–92.9 MiB). The warm closed-window footprint
still exceeds 50 MiB (tracked in issue #2); this short run is not a leak test.
The controller detaches previews and its document graph on close, but AppKit may
retain process allocations. Higher open-Settings memory is permitted by the user.
