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

## Scene-set downloads 0.3

80 integrated fixtures passed: 16 persistence/event/thumbnail, 22 core/policy,
42 catalog/adapter/movie/download. The 19 dedicated movie/catalog/downloader
fixtures use an injected transport and disposable generated raw video; they make
no network requests. They cover missing-only transfers, failures, cancellation,
concurrent destination preservation, URL/HTTP/size checks, movie validation and
bounded progress. Seven real FSEvents tests include same-inode nonempty movie
completion, manifest edits, missing directories, atomic file/folder replacement
and observer cleanup. Event tests require normal macOS service access; the local
execution sandbox rejected FSEventStreamStart, so these ran outside that sandbox.

The release app and embedded helper built, plist lint and strict ad-hoc signature
verification passed. A read-only probe recognized all 16 current native movies as
complete, including Tahoe’s four scenes. Actual private rendered captures show
Tahoe downloaded without stale labels, the missing-set Download Set button, and
Download Sonoma… in the menu. Disabled controls in those captures are intentional
read-only QA. New Sunset/Sunrise and Dusk/Dawn display labels preserve stored
phase identifiers. Download completion never selects or applies the browsed set.

Snark’s first weighted download-feature review scored 8.5/10 with no blocking
findings (correctness 2.2, safety 2.3, maintainability 1.2, evidence 1.1, UI 0.8,
updates 0.9). The quit cleanup finding was fixed before scoring: normal quit
awaits cancelled transfer cleanup. Final polish removes duplicate paused menu
lines and clarifies that extra set files are available rather than mandatory.
A complete production CDN movie transfer remains unverified; fixture evidence
must not be presented as proof of a live Apple download. No Apple media, private
screenshots or local coordinates are committed.

A real URLSession HEAD request to Tahoe Day’s native catalog URL returned HTTP
200, Content-Length 467,039,502 and zero body bytes from sylvan.apple.com. This
confirms endpoint/TLS reachability without downloading another movie; it does
not establish successful complete production transfer or installation.

### Bundled still previews

Fresh read-only inspection of this Mac found local 214 × 130 PNG previews for
all 97 assets in the 19 supported sets, independent of the 16 complete movies.
All five Sonoma previews exist even though all five movies are absent. The
Settings collection and scene menus use these local stills; no preview network
request or movie download is required. Unknown phase assignments remain empty.
The window owns a bounded thumbnail cache and releases its references on close.
Two generated-PNG fixtures verify local-only bounded decoding, missing-preview
retry and cache release. Actual native menu captures show all five undownloaded
Sonoma scene stills and a representative still for each collection. Screenshots
remain outside the repository.

## Enable the visible set 0.3.1

The reported failure was reproduced in the activation flow: Settings could show
unreviewed Tahoe while Enable still checked and applied the committed Golden Gate
selection. Enable now validates and saves the exact visible set and four scene
choices before compatibility checks or native application. Incomplete choices,
missing downloads and failed saves cannot fall back to another set. Runtime
readiness still follows the committed selection, so browsing a missing set does
not pause active rotation. Existing ready-set changes during active rotation
remain explicit live changes. Compatibility completion retains the accepted
selection rather than rereading a subsequently browsed set.

87 combined fixtures passed: 23 app/persistence/event/thumbnail/selection,
22 core/policy, 42 catalog/adapter/movie/download. Seven new selection tests
include reviewed/unreviewed Tahoe, real AppKit popup and switch action dispatch
through Settings and the coordinator, repeated renders and availability-label
changes, customized scene choices, missing downloads, both save-failure stages,
async compatibility completion and preservation of active rotation. Persistence,
compatibility service and final native apply are injected in those fixtures.
They do not claim external mouse automation; accessibility access was unavailable.
The release build, plist lint and strict ad-hoc signatures passed.

The installed app was gracefully replaced with 0.3.1 build 6. A private backup
preceded correction of the user's intended Tahoe selection and complete mapping
while the app was stopped; enabled state, location and receipt were preserved.
Normal startup then applied Tahoe Night through the existing native gateway.
Readback found all 30 managed Desktop/Idle/Linked selectors set to Tahoe Night;
the native Apple aerial process held that movie. The updated ownership receipt
matched Tahoe Night, its original restore baseline was unchanged, and no pending
operations remained. The ordinary rendered Settings showed Tahoe Night, rotation
enabled, its next transition and Start at Login enabled. This is live selector
and movie-activation evidence, not a new inspection of every Space or screen saver.

Snark's first weighted bug-fix review scored 8.3/10 with no blocking findings
(correctness 2.2, safety 2.2, maintainability 1.2, evidence 1.1, UI 0.8, updates 0.8).
Private screenshots, configuration backups and local coordinates remain outside
the repository. No new OS restart or morning transition was observed.
