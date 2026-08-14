import SwiftUI

@main
struct KeepAwakeMacApp: App {
    @StateObject private var awakeManager = AwakeManager()

    var body: some Scene {
        MenuBarExtra {
            AwakeMenuView()
                .environmentObject(awakeManager)
        } label: {
            Image(systemName: awakeManager.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                .accessibilityLabel(awakeManager.isActive ? "Keep Awake active" : "Keep Awake inactive")
        }
        .menuBarExtraStyle(.window)
    }
}
