# Launch at login — runtime verification

Sprekr uses `SMAppService.mainApp` on macOS 14 and later. A main-app login
launch is deliberately different from an interactive Finder, Dock, or Terminal
launch: it must start the menu-bar agent and optional Flow Bar without opening
the normal main window.

## Deterministic source check

Run this after a clean build:

```sh
make test
```

The test command includes the Command Line Tools' Swift Testing runtime where
needed. Its `InitialLaunchContextTests` suite creates the initial
`kAEOpenApplication` Apple event in memory and asserts that only Apple’s
`keyAEPropData == keyAELaunchedAsLogInItem` marker selects the quiet-launch
path. An ordinary open-application event and a different event type remain
interactive.

## Manual macOS 14 verification

This needs the owner present because System Settings and the logout/login cycle
are user-controlled.

1. Install the current app bundle in `/Applications`, then open it normally.
2. Finish onboarding if necessary. In **Settings → System**, enable **Launch
   at login** and keep **Show app in Dock** enabled for this test.
3. Confirm **Sprekr** appears in **System Settings → General → Login
   Items**. Do not add a duplicate item manually.
4. Choose **Quit Sprekr** from its menu-bar menu, then log out and log
   back in normally.
5. Expected immediately after login: Sprekr has a menu-bar item and, if
   enabled, its Flow Bar; it has no visible main window and does not activate
   itself or show a Dock icon yet.
6. Choose **Open Sprekr** from the menu-bar item. Expected: the main
   window appears, becomes key, and the Dock icon appears because the saved
   Dock preference is on.
7. Close the red window control. Expected: only the main window hides; the
   menu-bar item, configured global shortcut, and Flow Bar stay alive.
8. Disable **Launch at login**, quit, log out/in once more, and verify no Sprekr
   process or menu-bar item starts automatically.

Do not use `launchctl`, manually edit Login Items databases, or add a command
line launch-mode override to simulate this behavior. Those mechanisms do not
exercise `SMAppService.mainApp` or the login Apple event delivered by macOS.
