# Awake

Personal macOS menu bar app. It keeps the Mac awake and tracks weekday awake time against an 8-hour target. See README.md for what it does.

## Updating the installed app

Every change must end with a full replacement of the installed app. Never patch it in place or leave an old copy running.

- Install only with `./build.sh --install`. Do not copy the bundle by hand.
- The install must:
  1. Quit the running Awake gracefully (SIGTERM) so it saves today's time. Never `kill -9`.
  2. Abort if the old process is still alive after the wait.
  3. Delete `~/Applications/Awake.app` completely, then copy in the fresh bundle. No merging into the old bundle.
  4. Launch the new copy, then check that it runs from `~/Applications/Awake.app` and that its binary matches the one just built.
- There is exactly one installed copy, in `~/Applications/Awake.app`. If the script warns about another copy (for example in `/Applications`), tell the user. Do not delete it without asking.
- After installing, confirm with `pgrep -lx Awake` and `pmset -g assertions | grep -i awake`.
- User data is not part of the app and must survive updates: `~/Library/Application Support/Awake/history.json` and the `com.abhishek.awake` defaults.

## Rules

- Never run `sfltool` in any form. `resetbtm` wipes every login item on the Mac. The user checks Login Items in System Settings.
- Keep awake with IOKit power assertions only. Never simulate input.
- Pure logic (day splitting, reset time, weekend rule, battery cutoff) lives in `AwakeMath.swift`, with tests. Run `swift test` before installing.
