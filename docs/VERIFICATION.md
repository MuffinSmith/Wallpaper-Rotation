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

## Responsive set changes 0.3.2

The user reported a frozen interface when changing sets with rotation enabled.
A live five-second sample taken afterward showed an idle AppKit event loop; it
did not capture a persistent hang. A native Settings popup action using the
production adapter against a disposable recognized store with a delayed reload
reproduced temporary event-loop starvation: 0.424 seconds with zero 10 ms timer
ticks. Earlier selection tests injected an instantaneous final apply and missed
that behavior.

Native apply and Restore now run through a serialized worker away from the main
actor. Settings renders cached actual state and a busy status while the worker
finishes its journaled transaction. Rapid selections coalesce; Pause takes effect
immediately; Quit awaits native finalization and download cleanup while preserving
the next-launch rotation preference. The operation lease spans receipt persistence
and journal finalization. Failed cleanup leaves rotation paused with recovery
evidence retained. A no-op request never rolls back an earlier native application
when its configuration save fails.

An authorized live episode then exposed a separate restart timing error: rapid
changes could call `killall` while WallpaperAgent was between launchd restarts.
The adapter now waits up to six monotonic seconds for the current user's exact
process, with bounded child execution, explicit failures and cancellation. A
failed termination is retried only after confirmed process absence; the first
successful termination ends the request. Absence is never treated as success.

109 integrated fixtures passed: 31 app/persistence/events/interface, 22 core,
and 56 native/catalog/download/reload. Eight new interface tests use the production
adapter, a recognized temporary store and one-second reload delays. Actual AppKit
actions and main run-loop timers continue during native work. They cover rapid
choices, scene Save, Refresh/menu calls, Pause, close/reopen, Restore, Quit with
download cleanup, native errors, failed saves and denied journal cleanup. Fourteen
reload tests cover transient absence, probe/termination races, deadlines, errors,
and timeout/cancellation cleanup of disposable child processes. No fixture invokes
live Apple process commands or changes wallpaper.

The final private live episode passed in 5.395 seconds. With the normal app
gracefully stopped and a separate private configuration/recovery directory, native
Settings popup/switch actions exercised the same production worker and adapter.
Rapid Golden Gate → Tahoe changes succeeded; a second cycle verified all 29
current selectors and that Apple's aerial process opened each matching movie.
Control dispatch took approximately 1–18 ms. Pause and Settings close/reopen
worked, conditional Restore returned all 29 selectors to the starting Tahoe
scene, the private journal was removed, and the real saved configuration remained
byte-identical. Apple removed one native context during the earlier failed
episodes; it was preserved as an external topology change, rather than replaced
from a raw backup. The user's paused preference and original receipt stayed intact.

Snark's second scored candidate reached 8.6/10 with no blocking findings after the
live evidence (correctness 2.3, safety 2.2, maintainability 1.2, evidence 1.2,
UI 0.8, updates 0.9). The first provisional score was 8.5 before the live restart
timing failure was found and corrected. These are native AppKit action tests,
not external mouse automation; Accessibility access was unavailable. They do not
claim new verification of every Space, screen saver playback, an OS restart or a
morning transition. Startup/legacy visual recovery retains its existing bounded
synchronous path; normal apply/Restore and in-session events use the new boundary.

The final 0.3.2 build 7 release passed plist lint and strict ad-hoc signature
verification, then replaced the installed app at its existing Applications path.
Normal launch preserved the real configuration byte-for-byte, including paused
Tahoe, saved location, mappings and original ownership receipt; no pending records
remained. The actual rendered Settings showed Tahoe Night, downloaded/ready,
rotation off and Start at Login enabled. Four normal-release samples five seconds
apart with Settings never opened showed 0.0% CPU and 53,872–53,920 KiB RSS
(52.6–52.7 MiB). The under-50-MiB target remains open in issue #2. The prior app
and private recovery evidence remain available outside the repository.

## Equivalent native layouts 0.3.3

After the previous release, enabling Golden Gate applied its Night scene and then
persisted an outside-change pause. Fresh receipt/store comparison found one
Display's Linked entry replaced by individual Desktop and Idle entries, both
with identical Golden Gate configuration. All remaining owned configuration and
context values matched. macOS had changed the shape of the selection graph,
rather than the selected image. The old ownership check treated every branch
change as interference.

The adapter now accepts only strictly equivalent Linked ↔ Desktop/Idle layouts
within the same logical node. Every branch must match the complete configuration
and content context; only the validated synthetic node-type marker is projected.
Image, provider, file, shuffle, option and unknown-value differences remain
significant. Verification, the next apply and conditional restoration share this
projection. Original values follow equivalent branches without changing Apple's
current node type or unrelated metadata. Incompatible collapsed originals remain
retained as provenance and explicitly unrestorable; they are never replaced with
the app's currently managed image. Atomic conflict guards remain unchanged.

A new coordinator regression first reproduced the old failure after 0.858 seconds
through the real directory DispatchSource and debounce, after a production-adapter
apply had finished. Immediate readback and the earlier short live episode had
missed this later notification. The new test boundary injects only the native
store location and persistence/services; it keeps real native observation active.

123 combined fixtures passed: 32 app/event/interface, 22 core and 69 native. The
13 new adapter tests cover delayed/immediate rewrites, both layout directions,
original lineage across two subsequent applies and a full layout round trip,
ambiguous historical originals, genuine value changes and conditional restore.
The actual watcher regression now retains ON after an equivalent rewrite, then
persists OFF after a different asset appears in one branch.

A private live watched episode passed in 41.537 seconds: ordinary Golden Gate
Enable stayed ON through 30 seconds of real native directory observation; settled
Tahoe and Golden Gate changes verified all 29 current selectors and matching
Apple movie activation. Conditional restoration returned all 29 starting values
without changing the real app configuration. An explicit forward apply then left
the user's requested Golden Gate scene in place. Intermediate receipt snapshots
were retained privately. Native control dispatch took approximately 1–29 ms.

One earlier rapid Tahoe→Golden Gate attempt encountered a different real conflict:
Apple's writer restored the prior Tahoe asset during verification. The app paused
and conditional restore skipped values it could not prove it owned. This is not
equivalent layout normalization and is not ignored or blindly retried. Reliable
immediate consecutive changes remain a separate limitation in
[issue #8](https://github.com/MuffinSmith/Wallpaper-Rotation/issues/8). The successful
episode intentionally tested settled changes; it does not claim rapid-switch
reliability.

The 0.3.3 build 8 release passed plist lint and strict ad-hoc signature verification
and replaced the normal installed app. A guarded stopped-app migration resumed
only the automatic outside-change pause, preserving selection, mappings, location
and the original receipt. The normal installed app, with actual AppStorage and
production readiness gates, stayed enabled in samples every five seconds for
35 seconds, with no pending records and unchanged original restore values.
Its actual rendered Settings showed Golden Gate Night, Rotate Automatically on
and Start at Login on. Snark's first scored normalization review passed at 8.6/10
with no ordinary-Enable blockers (correctness 2.3, safety 2.3, maintainability 1.1,
evidence 1.2, UI 0.8, updates 0.9). No external mouse automation, new OS restart,
every-Space inspection, screen saver playback or morning transition is claimed.
