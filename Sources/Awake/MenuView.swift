import ServiceManagement
import SwiftUI

/// The popover: status + switch, today's progress, this week, settings, quit.
struct MenuView: View {
    let model: AppModel
    /// True only while the popover is on screen; gates the per-second updates.
    @State private var isVisible = false
    /// The "Day resets at" list is expanded. Lives here so a click anywhere else can close it.
    @State private var resetListOpen = false
    @State private var dropdownFrame: CGRect = .zero

    var body: some View {
        VStack(spacing: 0) {
            HeaderRow(power: model.power)
                .padding(EdgeInsets(top: 14, leading: 14, bottom: 12, trailing: 14))

            Divider()

            KeepAwakeSection(power: model.power)
                .padding(EdgeInsets(top: 14, leading: 14, bottom: 0, trailing: 14))

            // The live section re-evaluates once a second, but only while visible.
            // Closed, nothing here runs.
            Group {
                if isVisible {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        LiveSections(model: model, now: context.date)
                    }
                } else {
                    LiveSections(model: model, now: .now)
                }
            }

            Divider()

            SettingsSection(
                power: model.power, tracker: model.tracker, loginItem: model.loginItem,
                autoCharger: model.autoCharger, resetListOpen: $resetListOpen
            )
            .padding(EdgeInsets(top: 10, leading: 14, bottom: 8, trailing: 14))

            Divider()

            QuitRow()
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
        }
        .frame(width: 300)
        .coordinateSpace(name: PopoverSpace.name)
        .onPreferenceChange(DropdownFrameKey.self) { dropdownFrame = $0 }
        // While the list is open, a click anywhere outside the dropdown closes it.
        .overlay {
            if resetListOpen {
                OutsideCatcherShape(hole: dropdownFrame)
                    .fill(Color.clear)
                    .contentShape(OutsideCatcherShape(hole: dropdownFrame), eoFill: true)
                    .onTapGesture { closeResetList() }
            }
        }
        .onExitCommand { closeResetList() } // Escape
        .background(WindowVisibilityReader { visible in
            isVisible = visible
            if visible {
                model.refreshForDisplay()
            } else {
                resetListOpen = false // reopen collapsed
            }
        })
    }

    private func closeResetList() {
        withAnimation(.easeInOut(duration: 0.18)) { resetListOpen = false }
    }
}

// MARK: - Header

private struct HeaderRow: View {
    let power: PowerController

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Awake")
                .font(.headline)
            // The one place that says why things are paused or stopped.
            Text(power.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Keep awake

/// One segmented picker for the keep-awake mode, with a caption describing the selected
/// mode. The caption is always present, so the height never changes. The picker keeps the
/// saved mode but is disabled while the app is paused or stopped; the header says why.
private struct KeepAwakeSection: View {
    let power: PowerController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keep awake")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, cardInset)

            // A native segmented control keeps its natural width; it does not stretch. At the
            // regular size that is about 261 pt, wider than the 248 pt inside a normal card. So
            // this row gets nearly the whole card width, and the regular size fills it. If it
            // ever does not fit (larger text, another locale), the small size is used instead.
            ViewThatFits(in: .horizontal) {
                modePicker
                    .padding(.horizontal, 5)
                modePicker
                    .controlSize(.small)
                    .padding(.horizontal, cardInset)
                    .frame(maxWidth: .infinity)
            }

            Text(power.keepMode.caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, cardInset)
        }
        .padding(.vertical, cardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .disabled(power.pickerLocked)
    }

    /// Same inner margin as the other cards, so the text lines up with them.
    private let cardInset: CGFloat = 12

    private var modePicker: some View {
        Picker(
            "Keep awake",
            selection: Binding(get: { power.keepMode }, set: { power.setMode($0) })
        ) {
            ForEach(KeepAwakeMode.allCases, id: \.self) { mode in
                Text(mode.segmentTitle).tag(mode)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }
}

private extension KeepAwakeMode {
    var segmentTitle: String {
        switch self {
        case .off: "Off"
        case .screenCanSleep: "Screen off"
        case .screenOn: "Screen on"
        }
    }

    var caption: String {
        switch self {
        case .off: "Mac sleeps normally."
        case .screenCanSleep: "Screen goes dark. Work keeps running."
        case .screenOn: "Screen stays lit. Work keeps running."
        }
    }
}

// MARK: - Today + week (the parts that tick)

private struct LiveSections: View {
    let model: AppModel
    let now: Date

    private var calendar: Calendar { .autoupdatingCurrent }

    /// "Today" is the current work day: the one that started at the last reset time.
    private var today: Date { model.tracker.currentWorkDay(now: now) }

    var body: some View {
        VStack(spacing: 10) {
            TodayCard(
                seconds: model.tracker.seconds(on: today, now: now),
                now: now,
                isWeekend: calendar.isDateInWeekend(today),
                isCutOff: model.power.isCutOff,
                resetMinute: model.tracker.dayResetMinute
            )
            WeekCard(bars: weekBars, total: weekTotal)
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 14, trailing: 14))
    }

    private var weekBars: [WeekBar] {
        let today = today
        return AwakeMath.workweek(containing: today, calendar: calendar).map { day in
            WeekBar(
                date: day,
                seconds: model.tracker.seconds(on: day, now: now),
                isToday: calendar.isDate(day, inSameDayAs: today),
                isFuture: day > today
            )
        }
    }

    private var weekTotal: TimeInterval {
        weekBars.reduce(0) { $0 + $1.seconds }
    }
}

private struct TodayCard: View {
    let seconds: TimeInterval
    let now: Date
    let isWeekend: Bool
    let isCutOff: Bool
    let resetMinute: Int

    private var reachedGoal: Bool { seconds >= AwakeMath.dailyTarget }
    private var tint: Color { reachedGoal ? .green : .accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Today")
                    .font(.caption.weight(.medium))
                Spacer()
                Text("Resets at \(Format.clock(minutesAfterMidnight: resetMinute))")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.duration(seconds))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("of \(Int(AwakeMath.dailyTarget / 3600))h")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !isWeekend {
                ProgressCapsule(fraction: seconds / AwakeMath.dailyTarget, tint: tint)
            }

            detailLine
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    @ViewBuilder
    private var detailLine: some View {
        if isWeekend {
            Text("Weekend — not counting")
        } else if isCutOff {
            Text("Not counting — low battery")
        } else if reachedGoal {
            Text("Done · +\(Format.duration(seconds - AwakeMath.dailyTarget)) over")
        } else {
            let remaining = AwakeMath.dailyTarget - seconds
            Text("\(Format.duration(remaining)) left · done around \(Format.clock(now.addingTimeInterval(remaining)))")
        }
    }
}

private struct ProgressCapsule: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint)
                    // Never narrower than the bar is tall, so a tiny value still reads as a capsule.
                    .frame(width: clamped > 0 ? max(proxy.size.width * clamped, proxy.size.height) : 0)
            }
        }
        .frame(height: 8)
    }
}

private struct WeekCard: View {
    let bars: [WeekBar]
    let total: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("This week")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Week: \(Format.duration(total))")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            WeekChart(bars: bars)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

// MARK: - Settings

private struct SettingsSection: View {
    @Bindable var power: PowerController
    let tracker: AwakeTracker
    let loginItem: LoginItem
    let autoCharger: AutoCharger
    @Binding var resetListOpen: Bool

    var body: some View {
        VStack(spacing: 8) {
            ResetTimeDropdown(selection: tracker.dayResetMinute, isOpen: $resetListOpen) { minute in
                tracker.setDayReset(minute)
            }

            SettingRow("Stop everything below") {
                Picker("Stop everything below", selection: $power.batteryCutoffPercent) {
                    ForEach(AwakeMath.cutoffChoices, id: \.self) { percent in
                        Text("\(percent)%").tag(percent)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

            AutoChargeRows(autoCharger: autoCharger)

            SettingRow("Open at Login") {
                Toggle(
                    "Open at Login",
                    isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) })
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            if let message = loginItem.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else if loginItem.needsApproval {
                Button("Approve in System Settings…") {
                    SMAppService.openSystemSettingsLoginItems()
                }
                .font(.caption)
                .buttonStyle(.link)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The charger in one row: one menu for the auto-charge levels (5% steps, start
/// always above the cutoff) and a button that flips the smart plug. Auto-charge
/// is always on once the plug is set up. A caption appears only when something
/// needs attention.
private struct AutoChargeRows: View {
    @Bindable var autoCharger: AutoCharger

    var body: some View {
        HStack(spacing: 6) {
            Text("Charger")
                .font(.callout)
            Spacer(minLength: 4)
            levelsMenu
            chargerButton
        }
        .frame(minHeight: 22)

        if let problem {
            Text(problem)
                .font(.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Only failures and a missing setup are shown; the last success is in the button's tooltip.
    private var problem: String? {
        if !autoCharger.isSetUp { return "Plug not set up. Run Scripts/set-plug-credentials.sh." }
        return autoCharger.lastEventFailed ? autoCharger.lastEvent : nil
    }

    /// One button: shows whether the charger is on and flips it when clicked.
    private var chargerButton: some View {
        let on = autoCharger.plugIsOn
        return Button {
            autoCharger.togglePlug()
        } label: {
            HStack(spacing: 3) {
                if autoCharger.isBusy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: on == true ? "bolt.fill" : "bolt.slash")
                }
                Text(on == nil ? "–" : on! ? "On" : "Off")
                    .frame(minWidth: 22)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(on == true ? .green : nil)
        .disabled(autoCharger.isBusy || !autoCharger.isSetUp)
        .help(buttonHelp)
    }

    private var buttonHelp: String {
        let action = autoCharger.plugIsOn == true ? "Turn the Mac charger off" : "Turn the Mac charger on"
        guard let event = autoCharger.lastEvent, !autoCharger.lastEventFailed else { return action }
        return "\(action)\nLast: \(event)"
    }

    /// "20–95%": one menu listing both levels.
    private var levelsMenu: some View {
        Menu {
            Picker("Start charging at", selection: $autoCharger.startPercent) {
                ForEach(autoCharger.startChoices, id: \.self) { Text("\($0)%").tag($0) }
            }
            .pickerStyle(.inline)
            Picker("Stop charging at", selection: $autoCharger.stopPercent) {
                ForEach(autoCharger.stopChoices, id: \.self) { Text("\($0)%").tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Text("\(autoCharger.startPercent)–\(autoCharger.stopPercent)%")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Auto-charge: on at \(autoCharger.startPercent)%, off at \(autoCharger.stopPercent)%")
    }
}

private struct SettingRow<Control: View>: View {
    let title: String
    let control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.callout)
            Spacer(minLength: 8)
            control
        }
        .frame(minHeight: 22)
    }
}

// MARK: - Footer

private struct QuitRow: View {
    @State private var hovering = false

    var body: some View {
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            HStack {
                Text("Quit Awake")
                Spacer()
                Text("⌘Q")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.08) : .clear)
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut("q", modifiers: .command)
        .onHover { hovering = $0 }
    }
}

// MARK: - Shared style

private extension View {
    /// Grouped-section look: a soft rounded panel that sits on the popover material.
    func cardStyle() -> some View {
        padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
    }
}
