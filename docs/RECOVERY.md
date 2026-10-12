# Recovering a paused setup

A pause preserves the wallpaper currently on screen. After a manual Apple
wallpaper change, Resume Rotation evaluates the current time and uses your new
selection as the restore baseline. Restore Previous Setup changes only selectors
still owned by this app; later outside edits remain intact.

## Interrupted updates

Before changing native settings, the app saves a private pending-operation record.
The native adapter separately retains its ownership receipt before replacing the
wallpaper store. On launch, a matching recovery receipt is adopted and rotation
stays paused. Use Restore Previous Setup or inspect the result before resuming.
The original baseline is retained even if the process stopped before saving its
normal configuration. The compatibility helper uses `pending-smoke.json` for
each stage, retaining the original baseline across its Night and Day checks.
Recovery waits while another operation holds the native-operation lease.

If receipt identity or timing cannot be established, the app leaves rotation
disabled and retains the pending record and backups. It does not guess which
settings it owns. A fresh OS build also requires a compatibility check on explicit Enable.

## Starting over when recovery is uncertain

1. Quit Wallpaper Rotation. If an uncertain visual-check recovery prevents
   quitting, use macOS Force Quit; do not run another copy alongside it.
2. Copy `~/Library/Application Support/Wallpaper Rotation` somewhere safe.
   This retains configuration, pending records and original native backups.
3. In Apple's Wallpaper settings, explicitly choose the wallpaper and screen
   saver setup you want to use as your new baseline.
4. In the original app-support folder, rename any existing `config.json`,
   `pending-apply.json`, `pending-smoke.json`, `pending-verification.json`,
   `native-smoke-report.json` and `native-verification.json`
   by adding `.saved` to their names. Keep the `Backups` folder intact.
5. Reopen the app. It starts with rotation disabled. Select your set and location,
   then explicitly enable Rotation to run the compatibility check and resume.

This resets the app's ownership claim without overwriting Apple's current
settings. Raw `Index-*.plist` backups are inspection/recovery evidence; replacing
the live store wholesale can overwrite later changes to unrelated settings.

## Movies removed by macOS

While rotation is enabled, missing movies in the confirmed four-scene mapping
are restored automatically from Apple's catalog. Already downloaded movies are
kept. Settings shows restoration progress; Pause Rotation cancels the transfer
and keeps rotation paused. Manual pauses, outside wallpaper changes, uncertain
pending operations and unsupported native stores are not automatically resumed.

A failed transfer retries after five minutes, then fifteen minutes, then hourly.
The budget survives app restarts and successful transfers followed by another
purge. Check Downloads immediately recognizes files restored elsewhere without
bypassing that budget. The app waits until the confirmed mapping is ready, then
evaluates the current time before applying a scene.

Private diagnostic events are saved in `recovery-events.jsonl` and its rotated
`recovery-events.1.jsonl` beside `config.json`. Each file is limited to 256 KiB.
They contain version, phase, asset identifiers and outcome codes, without saved
coordinates or full restoration records. No administrator access is required.
