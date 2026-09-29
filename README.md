# Awake

A small personal menu bar app for macOS. It does three things:

1. **Keeps the Mac awake**, so long jobs (Claude Code, builds, downloads) keep running while you're away.
2. **Tracks how long the Mac is awake** each weekday, against an 8-hour target.
3. **Switches the Mac's charger on and off** through a smart plug, so the battery stays between two levels you choose.

The menu bar shows only an icon. Click it to see today's time, the week, and the settings.

| Icon | Meaning |
| --- | --- |
| ☕️ filled cup | Mac awake, screen can sleep |
| ☀️ sun | Mac awake, screen stays on |
| ☕️ empty cup | Off. The Mac sleeps normally |
| 💤 moon | Paused: lid closed or Low Power Mode |
| 🔋 low battery | Stopped: battery is below your cutoff |

## Keep awake

Pick a mode at the top of the menu:

- **Off**: the Mac sleeps normally.
- **Screen off** (default): the screen goes dark, work keeps running.
- **Screen on**: the screen stays lit.

It works like `caffeinate`: it asks macOS not to sleep. No fake mouse moves.

It pauses by itself when:

- **the lid is closed**, so closing the lid always lets the Mac sleep.
- **Low Power Mode is on**.
- **the battery is low.** "Stop everything below" (default 20%) stops the whole app while on battery below that level. It starts again when you plug in or the charge comes back up.

## Awake time

- Time counts while the Mac is awake and the lid is open.
- **Only weekdays count.** Saturday and Sunday are ignored.
- **The day resets at a time you choose** (default 7:00 AM). With a 7:00 reset, 2:00 AM Wednesday still counts for Tuesday.
- Sleep time is never counted. A gap of 90 seconds or more is treated as sleep.
- You get one notification when you reach 8 hours in a day.
- History is kept for 60 days in `~/Library/Application Support/Awake/history.json`.

## Auto-charge (smart plug)

Plug the Mac's charger into a Tuya-based smart plug (for example Wipro). Once the plug is set up (see below), Awake switches it for you. There is no on/off switch for this; it's always on.

- **On** when the Mac is on battery and falls to the start level (default 30%).
- **Off** when the Mac is charging and reaches the stop level (default 90%).
- **In between, it leaves the plug alone.**

The menu shows it in one row:

```
Charger              30–90% ▾   [⚡ Off]
```

- **30–90% ▾** sets both levels. Click it to pick "Start charging at" and "Stop charging at".
- **[⚡ Off]** shows whether the charger is on. Click it to flip it. Your choice holds until the battery reaches the other level. For example, turn it on at 95% and it stays on; auto-charge takes over again when the battery next falls to the start level. Hover over it to see the last thing that happened.

Details:

- Both levels move in 5% steps. Start is always above "Stop everything below". Stop goes up to 100%.
- **It talks to the plug over your home Wi-Fi only.** No cloud.
- **No polling.** macOS tells the app when the battery changes.
- **If the plug doesn't answer**, it tries again a minute later and sends a notification.
- **If the Mac isn't charging a minute after switching on**, you get a notification.
- A red line appears under the row only when something is wrong, like the plug not answering.
- Nothing happens while the Mac is asleep. It catches up when the Mac wakes.

Things to know:

- **Allow network access once.** The first time, macOS asks "Awake would like to find devices on your local network". Click Allow. You can change it later in System Settings → Privacy & Security → Local Network.
- **macOS may stop charging at 80%** to protect the battery. If it does, a Stop level above 80% is never reached. Set Stop to 80% or lower, or turn that macOS feature off.

### Plug setup

The plug's ID, key and address are kept in your Mac's **Keychain**. They are never in this repo. Save them with:

```sh
Scripts/set-plug-credentials.sh                  # asks for each value; the key is hidden
Scripts/set-plug-credentials.sh --from-env FILE  # reads them from a .env file
```

Run it again if the plug gets a new address or is paired again. No restart needed.

Tip: reserve the plug's address in your router so it never changes.

## Build and install

Needs macOS 14 or later on Apple Silicon, and Xcode or its command line tools.

```sh
swift test             # run the tests
./build.sh             # build build/Awake.app
./build.sh --install   # build, replace ~/Applications/Awake.app, and open it
```

`--install` quits the running app gently first, so today's time is saved. On first launch the app turns on "Open at Login" once. You can switch it off in the menu.

## Uninstall

1. In the menu, turn off **Open at Login**, then choose **Quit Awake**.
2. Delete `~/Applications/Awake.app`.
3. Optional: delete `~/Library/Application Support/Awake`, run `defaults delete com.abhishek.awake`, and remove the "Awake smart plug" item from Keychain Access.

## Code layout

```
build.sh                        build, sign, install
Resources/Info.plist            app settings (bundle ID, network permission text)
Scripts/make-icon.swift         draws the app icon
Scripts/set-plug-credentials.sh saves the plug details to the Keychain
Sources/Awake/
  AwakeApp.swift                app entry, menu bar icon
  AppModel.swift                connects everything: timer, sleep/wake, quit
  PowerController.swift         keep-awake, lid, battery, Low Power Mode
  KeepAwakeSettings.swift       the keep-awake mode setting
  SystemPower.swift             reads lid and battery from macOS
  AwakeTracker.swift            counts and saves awake time
  AwakeMath.swift               pure logic (days, weekends, battery levels), tested
  MenuView.swift                the menu
  WeekChart.swift               the Mon–Fri chart
  LoginItem.swift               Open at Login
  Notifier.swift                notifications
  Format.swift                  time formatting
  Plug/AutoCharger.swift        when to switch the plug, retries, status
  Plug/SmartPlug.swift          sends one command to the plug
  Plug/TuyaProtocol.swift       the plug's message format and encryption, tested
  Plug/PlugCredentials.swift    reads the plug details from the Keychain
Tests/AwakeTests/               tests
```
