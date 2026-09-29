import SwiftUI

/// "Day resets at": a row with the current time, which expands an inline list of
/// 144 times (10-minute steps) exactly five rows tall.
///
/// This replaces the system pop-up menu, which opens a full-screen list of all 144
/// entries. The list here lives inside the popover, so it can never grow past five rows.
struct ResetTimeDropdown: View {
    /// Selected time, in minutes after midnight.
    let selection: Int
    @Binding var isOpen: Bool
    let onSelect: (Int) -> Void

    static let visibleRows = 5
    static let rowHeight: CGFloat = 26

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Day resets at")
                    .font(.callout)
                Spacer(minLength: 8)
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { isOpen.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text(Format.clock(minutesAfterMidnight: selection))
                            .monospacedDigit()
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isOpen ? 180 : 0))
                    }
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(isOpen ? 0.14 : 0.08))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Day resets at \(Format.clock(minutesAfterMidnight: selection))")
            }
            .frame(minHeight: 22)

            if isOpen {
                TimeList(selection: selection) { minute in
                    onSelect(minute)
                    withAnimation(.easeInOut(duration: 0.18)) { isOpen = false }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        // Report this whole block's frame so the popover can treat clicks outside it as "close".
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: DropdownFrameKey.self, value: proxy.frame(in: .named(PopoverSpace.name)))
            }
        )
    }
}

/// The scrolling list: `visibleRows` rows tall, opened scrolled so the selection sits in the middle.
private struct TimeList: View {
    let selection: Int
    let onSelect: (Int) -> Void
    /// The row the scroll view is positioned on. Starts at the selection, which puts it
    /// in the middle; it then follows the user's scrolling and is not the selection.
    @State private var position: Int?

    init(selection: Int, onSelect: @escaping (Int) -> Void) {
        self.selection = selection
        self.onSelect = onSelect
        _position = State(initialValue: selection)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(AwakeMath.resetMinuteChoices, id: \.self) { minute in
                    TimeRow(minute: minute, isSelected: minute == selection) { onSelect(minute) }
                        .id(minute)
                }
            }
            .scrollTargetLayout()
        }
        // A declarative starting position works with lazy rows; `scrollTo` on appear ran before they existed.
        .scrollPosition(id: $position, anchor: .center)
        .frame(height: CGFloat(ResetTimeDropdown.visibleRows) * ResetTimeDropdown.rowHeight)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
        )
    }
}

private struct TimeRow: View {
    let minute: Int
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(Format.clock(minutesAfterMidnight: minute))
                    .monospacedDigit()
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                }
            }
            .font(.callout)
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: ResetTimeDropdown.rowHeight)
            .background(rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var rowBackground: Color {
        if hovering { return Color.primary.opacity(0.10) }
        if isSelected { return Color.accentColor.opacity(0.14) }
        return .clear
    }
}

// MARK: - Popover plumbing

enum PopoverSpace {
    static let name = "awake.popover"
}

/// The dropdown's frame inside the popover, used to leave a hole in the click-outside catcher.
struct DropdownFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// A full-size shape with a rectangular hole (even-odd fill). Clicks land on the shape
/// everywhere except the hole, so it can catch "outside" clicks without covering the dropdown.
struct OutsideCatcherShape: Shape {
    let hole: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addRect(hole)
        return path
    }
}
