# Awake

A small personal menu bar app for macOS. It does two things:

1. **Keeps the Mac awake** so long terminal sessions (Claude Code, builds, downloads) keep running while you are away.
2. **Tracks how long the Mac is awake** each weekday against an 8-hour target. It resets daily and ignores Saturday and Sunday. The time is shown only inside the menu, never in the menu bar.

The menu bar shows just an icon:

| Icon | Meaning |
| --- | --- |
| `cup.and.saucer.fill` | Mac awake, screen can sleep |
| `sun.max.fill` | Mac awake, screen kept on |
| `cup.and.saucer` | Off: the Mac sleeps normally |
| `moon.zzz` | Paused (lid closed or Low Power Mode) |
| `battery.25` | Stopped because the battery is below your cutoff |

Click it for today's time, a progress bar with "done around" time, the Mon-Fri chart with a weekly total, and the keep-awake mode picker, and the settings (when the day resets, the low-battery cutoff, Open at Login). The header line says what is happening: "Mac awake · screen on", "Mac awake · screen can sleep", "Off — Mac sleeps normally", or why it is paused or stopped.

## How keep-awake works, and why it is battery-safe

Awake takes an IOKit power assertion, `PreventUserIdleSystemSleep`. It is exactly what `caffeinate -i` does. It tells macOS "do not idle-sleep the system while this is held". No mouse jiggling or fake input is involved.

- **One segmented picker, right under the header: Off | Screen off | Screen on.** A caption under it describes the selected mode and is always there, so the popover never changes height:
  - **Off** ("Mac sleeps normally.") holds nothing.
  - **Screen off** ("Screen goes dark. Work keeps running.") holds `PreventUserIdleSystemSleep` only. This is the default.
  - **Screen on** ("Screen stays lit. Work keeps running.") holds `PreventUserIdleDisplaySleep` and also `PreventUserIdleSystemSleep` (redundant, but explicit).
  - The screen still sleeps in the default mode, which is where most of the battery goes. Older versions saved this as two separate settings; the first launch of this version converts them into the one mode and removes the old keys.
- **The assertions are held only when all of these are true:** a mode other than off is selected, the lid is open, the battery cutoff has not stopped the app, and Low Power Mode is off. It is re-evaluated on every change.
- **Paused or stopped:** the picker stays visible showing the saved mode but is disabled, and the header line gives the reason once.
- **Lid closed:** the assertion is released and tracking pauses, so closing the lid always lets the Mac sleep. (The lid is read from `AppleClamshellState` on `IOPMrootDomain`. On a desktop Mac with no lid it counts as open.)
- **Low Power Mode:** keep-awake pauses. Awake-time counting continues.
- **Low-battery cutoff, "Stop everything below" (10-80%, default 20%):** when on battery power and the charge is below the chosen percentage, the whole app goes dormant. All assertions (system and display) are released, awake-time counting stops (time up to that moment is kept, nothing more is added), and the 8-hour notification is suppressed. The keep-awake picker keeps the saved mode but is disabled and has no effect. The app keeps running, and resumes on its own when you plug in or the charge is back at or above the threshold. The popover shows "Stopped — battery below N% (on battery)"; the settings and Quit still work.
- **Idle cost is tiny.** There is one 30-second timer with 10 seconds of tolerance, and lid, battery and Low Power Mode changes arrive as notifications (the timer also re-reads them as a fallback). The per-second clock in the popover runs only while the popover is open.

## How the time is counted

- Wall time counts while the system is awake, the lid is open and the app is not battery-stopped. It is independent of the keep-awake mode (it measures awake time, not assertion time).
- **The day resets at a time you choose ("Day resets at", default 7:00 AM, 10-minute steps).** A work day runs from the reset time on date D to the reset time on D+1 and is filed under D, so nothing is dropped. With a 7:00 reset, Tue 07:00 up to Wed 06:59 all counts toward Tuesday, and Wed 02:00 counts toward Tuesday. "Today" in the menu is the current work day. A reset of 12:00 AM makes it a plain calendar day.
- **Weekends:** a work day counts only if its filing date is Monday to Friday. Fri 07:00 to Sat 07:00 counts for Friday. Sat 07:00 to Mon 07:00 counts for nothing, and Sun 23:00 to Mon 06:00 counts for nothing because it falls under Sunday.
- Changing the reset time applies from then on; time already stored is never re-bucketed.
- Every 30 seconds the elapsed time is added to the current work day. A gap of 90 seconds or more is treated as "the Mac was asleep" and dropped. Going to sleep saves the time first; waking restarts the clock from now.
- An interval that crosses a reset boundary is split so each work day gets its own share. Reset boundaries are built with the calendar, so days that change length for daylight saving stay correct.
- History is stored as JSON in `~/Library/Application Support/Awake/history.json` (`yyyy-MM-dd` to seconds). The last 60 days are kept.
- When the current work day first reaches 8 hours you get one local notification ("8 hours done today"), at most once per work day. If notifications are denied it is simply skipped.

## Build and install

Needs macOS 14+ on Apple Silicon and Xcode (or its command line tools) with Swift 6.

```sh
./build.sh             # builds build/Awake.app (release, arm64, ad-hoc signed)
./build.sh --install   # also quits a running Awake, copies to ~/Applications/Awake.app, opens it and checks the result
swift test             # runs the unit tests
```

Each build gets a timestamp as its bundle version. `--install` refuses to install over a process that will not quit (it never force-kills, which would lose unsaved time), warns about other `Awake.app` copies elsewhere on the disk (it does not delete them), and afterwards checks that the running process is the one in `~/Applications` and that the installed binary is identical to the one just built.

The app icon is drawn by `Scripts/make-icon.swift` during the build; if that step fails the build still succeeds without an icon.

On the very first launch from an Applications folder, the app turns "Open at Login" on by itself (once; it never turns it back on if you switch it off). You can change it any time with the "Open at Login" toggle in the menu, or in System Settings > General > Login Items.

## Uninstall

1. Click the menu bar icon and turn off **Open at Login** (or remove Awake under System Settings > General > Login Items).
2. Choose **Quit Awake** from the same menu.
3. Delete `~/Applications/Awake.app`.
4. Delete `~/Library/Application Support/Awake` (the history), and optionally the preferences with `defaults delete com.abhishek.awake`.

## Layout

```
Package.swift            Swift package (executable target + tests)
build.sh                 builds and signs Awake.app, optional --install
Resources/Info.plist     bundle template (LSUIElement, com.abhishek.awake)
Scripts/make-icon.swift  draws AppIcon.icns
Sources/Awake/
  AwakeApp.swift         @main, MenuBarExtra
  AppModel.swift         timer, sleep/wake, quit, first-launch setup
  PowerController.swift  assertions, lid, battery cutoff, Low Power Mode
  KeepAwakeSettings.swift the keep-awake mode, its migration and saving
  SystemPower.swift      IOKit reads (lid, battery) and assertion calls
  AwakeTracker.swift     tick, sleep/wake, persistence, day buckets
  AwakeMath.swift        pure logic: work-day splitting, week, pruning, battery cutoff, keep-awake mode
  HistoryStore.swift     history.json
  MenuView.swift         the popover
  WeekChart.swift        the Mon-Fri bars
  LoginItem.swift        Open at Login (SMAppService)
  Notifier.swift         the 8-hour notification
  Format.swift           duration and clock formatting
Tests/AwakeTests/        pure logic and tracker tests
```
