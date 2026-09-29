import SwiftUI

@main
struct AwakeApp: App {
    private let model = AppModel.shared

    var body: some Scene {
        // Menu bar icon only, never text. The symbol is a template image, so it
        // adapts to light and dark menu bars.
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            Image(systemName: model.power.iconName)
                .accessibilityLabel("Awake")
        }
        .menuBarExtraStyle(.window)
    }
}
