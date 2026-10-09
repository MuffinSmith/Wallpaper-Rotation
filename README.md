# Wallpaper Rotation

A small native macOS menu bar app that rotates Apple's aerial wallpaper and
matching screen saver around sunrise and sunset. It uses native Apple
movies and can download missing scenes directly from Apple’s catalog. It does not
render video itself. No third-party packages or subscriptions.

Requires **macOS 27 and Apple Silicon**. Apple's automatic appearance settings
are preserved. Wallpaper changes follow solar times; Apple's theme can change
later because Auto appearance waits for idle time.

| Time | Scene |
| --- | --- |
| Hour before sunrise | Dusk / Dawn |
| Sunrise to one hour afterward | Sunset / Sunrise |
| One hour after sunrise to one hour before sunset | Day |
| Hour before sunset | Sunset / Sunrise |
| Sunset to one hour afterward | Dusk / Dawn |
| Remaining nighttime | Night |

## Build

Install Apple's Command Line Tools if necessary (`xcode-select --install`), then:

```sh
git clone https://github.com/MuffinSmith/Wallpaper-Rotation.git
cd Wallpaper-Rotation
bash scripts/test.sh
bash scripts/build-app.sh
```

The result is `build/Wallpaper Rotation.app`. The script signs the local build
ad-hoc. For an existing persistent signing identity, set `SIGNING_IDENTITY` when
building. It does not create certificates, alter Keychain, or notarize a release.

## Use

1. Move the app to a stable location, such as `~/Applications`, and open it.
2. Select an Apple collection. Golden Gate is the default. Use **Download Set**
   in Settings, or **Download [set]…** in the menu, for missing scenes. Downloads
   come from Apple’s catalog and save to the native movie cache. Completed Apple
   downloads are recognized automatically; partial movies stay unavailable.
   Set and scene menus show Apple’s small bundled previews even before the full
   videos are downloaded. Unassigned phases remain yours to choose.
   Review proposed role mappings for unfamiliar sets. Download completion leaves
   your current wallpaper and rotation selection intact until you confirm the set.
3. Use **Change…** in Location to choose this Mac’s location or provide coordinates. A saved location supports
   temporary outages; location updates use occasional one-shot requests.
4. Enable **Rotation**. If this OS build has not been checked, the app briefly
   tests Day and Night, restores your setup, then starts the current scene.
   Enable saves the set and four scene choices currently shown in Settings.
   Incomplete or undownloaded choices block activation and explain what is missing.
   First launch leaves wallpaper unchanged until you enable rotation.
5. Optionally enable Start at Login. Its switch reflects macOS's actual
   registration status; an unsigned/ad-hoc build may require approval or fail.

The menu shows the actual scene and next transition. Pausing leaves the current
wallpaper in place. A manual wallpaper change pauses rotation across relaunches.
All monitors and Spaces share the selected scheduled scene while rotation runs.

## Updates and recovery

Apple does not provide a supported public interface for selecting native aerial
movies across Spaces. This app validates the current wallpaper store, preserves
unrelated fields, and stops on unsupported structures or conflicting changes.
After an OS update, rotation pauses. Enable it to run a fresh native compatibility
check before scheduling resumes. Compatibility is checked;
it is **not guaranteed across future macOS updates**.

Normal restore conditionally reverses only values the app still owns. It leaves
later manual changes alone. Raw backups are retained for inspection, not blindly
written over newer settings. See the [recovery guide](docs/RECOVERY.md) for an
interrupted or uncertain update. Atomic replacement prevents torn writes; Apple does
not participate in the app's lock, so concurrent settings changes cannot be made
fully transactional.

Rebuild updates outside the installed app, quit, and replace the app at the same
path. Keep a persistent signer to improve permission continuity. Ad-hoc signing
does not promise that location grants survive rebuilding.

To remove the app: disable Start at Login, optionally Restore Previous Setup,
quit, and delete the app. Configuration/backups live in
`~/Library/Application Support/Wallpaper Rotation`; remove that folder only if
you no longer want the saved settings or recovery evidence.

## Diagnostics and verification

Read-only commands:

```sh
"build/Wallpaper Rotation.app/Contents/MacOS/WallpaperDiagnostics" --catalog
"build/Wallpaper Rotation.app/Contents/MacOS/WallpaperDiagnostics" --inspect
"build/Wallpaper Rotation.app/Contents/MacOS/WallpaperDiagnostics" --schedule 37.77 -122.42
```

The explicitly opt-in live smoke command briefly switches downloaded Golden Gate
Day/Night scenes, verifies selector readback and the native movie process, then
conditionally restores the original selections:

```sh
"build/Wallpaper Rotation.app/Contents/MacOS/WallpaperDiagnostics" --native-smoke --allow-live-changes
```

The app passes the selected set’s Day and Night asset IDs to this check. For
manual testing of another set, append `--assets dayID nightID`.

This does **not** prove the visible appearance of every monitor/Space, animated
screen saver playback, or ordinary restart behavior. Those checks require actual
observation. See [verification evidence](docs/VERIFICATION.md).

## License

MIT, copyright 2026 Grant Ross and contributors. Apple's media is neither
included nor relicensed. No images or videos are committed to this repository.
