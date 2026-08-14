import SwiftUI
import AppKit

struct AwakeMenuView: View {
    @EnvironmentObject private var manager: AwakeManager

    @AppStorage("selectedDuration") private var selectedDurationRaw = SessionDuration.indefinite.rawValue
    @AppStorage("customMinutes") private var customMinutes = 45
    @AppStorage("allowDisplaySleep") private var storedAllowDisplaySleep = true

    private var selectedDuration: Binding<SessionDuration> {
        Binding(
            get: { SessionDuration(rawValue: selectedDurationRaw) ?? .indefinite },
            set: { selectedDurationRaw = $0.rawValue }
        )
    }

    private var currentDuration: TimeInterval? {
        (SessionDuration(rawValue: selectedDurationRaw) ?? .indefinite)
            .seconds(customMinutes: customMinutes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: manager.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(.system(size: 24))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep Awake")
                        .font(.headline)
                    Text(manager.isActive ? statusText : "Mac can sleep normally")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("Session", isOn: Binding(
                    get: { manager.isActive },
                    set: { enabled in
                        if enabled {
                            manager.allowDisplaySleep = storedAllowDisplaySleep
                            manager.start(duration: currentDuration)
                        } else {
                            manager.stop()
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            if manager.isActive {
                Label("Strong keep-awake mode active", systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Duration")
                    .font(.subheadline.weight(.semibold))

                Picker("Duration", selection: selectedDuration) {
                    ForEach(SessionDuration.allCases) { duration in
                        Text(duration.title).tag(duration)
                    }
                }
                .pickerStyle(.menu)
                .disabled(manager.isActive)

                if selectedDuration.wrappedValue == .custom {
                    HStack {
                        Text("Minutes")
                        Spacer()
                        TextField("Minutes", value: $customMinutes, format: .number)
                            .frame(width: 70)
                            .textFieldStyle(.roundedBorder)
                            .disabled(manager.isActive)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Display")
                    .font(.subheadline.weight(.semibold))

                Toggle("Allow display to sleep while lid is open", isOn: Binding(
                    get: { storedAllowDisplaySleep },
                    set: { newValue in
                        storedAllowDisplaySleep = newValue
                        manager.allowDisplaySleep = newValue
                        if manager.isActive {
                            manager.restartForDisplayPreferenceChange(duration: currentDuration)
                        }
                    }
                ))

                Text(storedAllowDisplaySleep
                     ? "Idle display sleep is allowed, while the Mac is kept awake. This applies with the MacBook lid open."
                     : "The Mac and its display are both kept awake during the session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Label("MacBook lid", systemImage: "laptopcomputer")
                    .font(.subheadline.weight(.semibold))

                Text("Closing the built-in lid is a separate macOS sleep request. KeepAwakeMac cannot reliably override it or keep the graphical user session unlocked. Apple's supported closed-lid setup uses external power, an external display, and an external keyboard/mouse.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = manager.lastError {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Button("Lock Screen Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)

                Spacer()

                Button("Quit") {
                    manager.stop()
                    NSApplication.shared.terminate(nil)
                }
            }

            Text("When a timed session ends, normal macOS sleep and lock settings resume.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 360)
        .onAppear {
            manager.allowDisplaySleep = storedAllowDisplaySleep
        }
    }

    private var statusText: String {
        guard let remaining = manager.remainingSeconds else {
            return "Active indefinitely"
        }

        let total = Int(remaining.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        if hours > 0 {
            return String(format: "Active · %d:%02d:%02d remaining", hours, minutes, seconds)
        }
        return String(format: "Active · %d:%02d remaining", minutes, seconds)
    }
}
