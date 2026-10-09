# Development guide

The project has four Swift Package targets:

| Target | Responsibility |
| --- | --- |
| RotationCore | Value types and offline solar phase calculations; no macOS settings access. |
| AppleWallpaper | Native catalog discovery and guarded wallpaper-store transactions. |
| WallpaperRotation | AppKit interface, location events, persistence, and the single transition timer. |
| WallpaperDiagnostics | Read-only inspection and explicitly opt-in native round-trip checks. |

Run `bash scripts/test.sh` for fixture tests and `bash scripts/build-app.sh` for
an ad-hoc signed release app. Command Line Tools are sufficient; no external
Swift packages are used. A persistent signing identity can be supplied through
`SIGNING_IDENTITY` without changing source code.

## Changing behavior

Keep solar decisions independent of local calendar presentation. All phase
shoulders are 3,600 elapsed seconds. Tests use independently published solar
times and synthetic boundary cases.

Discover Apple collections from category/subcategory membership. Treat Apple's
asset IDs and available media as runtime data. New or ambiguous collections
require reviewed phase mappings; do not infer times from gallery order.

The wallpaper store is undocumented. Extend its adapter only with fixtures and
observed native evidence. Preserve unrelated fields and reject unknown structures.
Use the cooperative transaction lock, stale-read checks, ownership receipts and
conditional restore together. The whole-operation lease serializes helpers, app
writes and recovery; reread pending stages under that lease. None provides a transaction with Apple's writer.

UI readiness must represent observed success. Native compatibility is checked on
explicit Enable; fixture tests cannot produce a passing live smoke report. Keep desired selections distinct from
actual native state and reflect startup registration from macOS's own service.

Native transactions can wait for file locks, disk writes and Apple's wallpaper
process. Keep them off the main actor, serialize each apply/restore episode, and
retain its operation lease until ownership persistence and journal cleanup finish.
Render cached native state during an operation. A later selection may replace the
queued request; Pause takes effect immediately, and Quit waits for finalization.
Responsiveness fixtures must use the production adapter with a delayed reload and
dispatch native control actions while a main run-loop timer continues to fire.
An instantaneous fake apply cannot establish this property.

macOS may rewrite a shared Linked selection as matching Desktop and Idle
selections after reloading. Ownership must compare the complete configuration
and content context for both branches before accepting that equivalent layout.
Exclude only the synthetic node-type marker; asset, provider, files, options and
unknown values remain significant. Apply and conditional restore must use the
same projection so original values follow equivalent branches without rewriting
Apple's current node type. Ambiguous merged originals must never be guessed.
One observed layout exception retains the complete owned Desktop
context while combining or separating an Idle context with exactly empty encoded option values.
Accept only the validated Crop and GenericRGB color option shape; preserve exact
Desktop equality and all other context fields. This is a bounded representation
rule, not proof of the actor that changed the store. Validate the whole pair before
projecting either selector; an empty or changed Desktop is never accepted. Unknown options or meaningful
Idle options remain interference. Original restore contexts are not normalized
by this exception; ambiguous baselines stay retained and skipped.
Exercise delayed rewrites through the actual directory watcher and debounce;
an immediate readback or a coordinator without observation can miss this case.

Refreshes must reconcile an overdue phase before replacing its next-transition
timer. Check ownership before catch-up, respect paused/pending/startup gates,
and listen for session activation as well as wake. Use one timer in common run-loop
modes so an open menu cannot starve it. Keep the injectable clock at the coordinator
boundary; tests should advance Night to Day without waiting overnight. Label such
tests separately from real login, reboot, or overnight observations.

## Pull requests

Keep main buildable. Include the concrete behavior change and relevant test
results. Native display checks, permission behavior and resource measurements
must be described separately from fixture tests; document pending evidence.
Never commit Apple's media, local coordinates, recovery backups, compiled apps,
private signing keys, or temporary build/review logs.

CI uses the [official Xcode 27 arm64 runner image](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md),
which supplies macOS 27. Check the PR’s workflow result separately from local tests.
When updating the deployment target, update and verify this runner choice too.
