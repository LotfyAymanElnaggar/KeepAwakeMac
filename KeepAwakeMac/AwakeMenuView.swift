import SwiftUI
import AppKit

struct AwakeMenuView: View {
    @EnvironmentObject private var manager: AwakeManager

    @AppStorage("selectedDuration") private var selectedDurationRaw = SessionDuration.indefinite.rawValue
    @AppStorage("customMinutes") private var customMinutes = 45
    @AppStorage("allowDisplaySleep") private var storedAllowDisplaySleep = true
    @AppStorage("lowBatteryCutoff") private var storedLowBatteryCutoff = 15

    @State private var diagnosticsCopied = false

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
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                sessionHeader
                Divider()
                durationSection
                Divider()
                displaySection
                Divider()
                lidSection
                Divider()
                securitySection

                if let error = manager.lastError {
                    Divider()
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let message = manager.lidStatusMessage {
                    Label(message, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()
                footer
            }
            .padding(16)
        }
        .frame(width: 400, maxHeight: 690)
        .onAppear {
            manager.allowDisplaySleep = storedAllowDisplaySleep
            manager.lowBatteryCutoff = storedLowBatteryCutoff
            Task { await manager.prepareOnLaunch() }
        }
    }

    private var sessionHeader: some View {
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
                        manager.lowBatteryCutoff = storedLowBatteryCutoff
                        manager.start(duration: currentDuration)
                    } else {
                        Task { await manager.stopAndRestoreSleep() }
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
    }

    private var durationSection: some View {
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
    }

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Display")
                .font(.subheadline.weight(.semibold))

            Toggle("Allow display to turn off", isOn: Binding(
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
                 ? "The display may turn off while the Mac stays awake."
                 : "Both the Mac and display are kept awake during the session.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var lidSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("MacBook lid", systemImage: "laptopcomputer")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if manager.sleepDisabledReadback {
                    Text("SleepDisabled = 1")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            if manager.lidAuthorizationInstalled {
                Toggle("Keep running with lid closed", isOn: Binding(
                    get: { manager.lidClosedModeEnabled },
                    set: { enabled in
                        Task { await manager.setLidClosedMode(enabled) }
                    }
                ))
                .disabled(!manager.isActive || manager.lidChanging)

                HStack {
                    Text("Low-battery safety")
                    Spacer()
                    Picker("Low-battery safety", selection: Binding(
                        get: { storedLowBatteryCutoff },
                        set: { value in
                            storedLowBatteryCutoff = value
                            manager.lowBatteryCutoff = value
                        }
                    )) {
                        Text("10%").tag(10)
                        Text("15%").tag(15)
                        Text("20%").tag(20)
                        Text("25%").tag(25)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 85)
                }

                if let battery = manager.batteryPercent {
                    Text("Battery: \(battery)%\(manager.onBatteryPower ? " · on battery power" : " · external power")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Remove Lid Authorization…") {
                    Task { await manager.removeLidAuthorization() }
                }
                .buttonStyle(.link)
                .disabled(manager.lidChanging)
            } else {
                Text("Lid-closed mode needs one administrator approval. The installed rule is narrowly limited to exactly two commands: turning macOS SleepDisabled on and off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(manager.lidChanging ? "Installing…" : "Install Lid Authorization…") {
                    Task { await manager.installLidAuthorization() }
                }
                .disabled(manager.lidChanging)
            }

            Label("Safety: do not use lid-closed mode inside a bag, sleeve, or other poorly ventilated space.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Lock behavior")
                .font(.subheadline.weight(.semibold))

            Text("Keeping the computer running and requiring a password when the display turns off are separate macOS settings. If you want to reopen the lid without a login prompt, set ‘Require password after screen saver begins or display is turned off’ to Never in Lock Screen settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Open Lock Screen Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)

                Spacer()

                Text("No password is stored by this app")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button(diagnosticsCopied ? "Diagnostics Copied" : "Copy Diagnostics") {
                Task {
                    let text = await manager.diagnostics()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    diagnosticsCopied = true
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    diagnosticsCopied = false
                }
            }
            .buttonStyle(.link)

            Spacer()

            Button("Quit") {
                Task {
                    await manager.stopAndRestoreSleep()
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    private var statusText: String {
        guard let remaining = manager.remainingSeconds else {
            return manager.lidClosedModeEnabled ? "Active indefinitely · lid mode armed" : "Active indefinitely"
        }

        let total = Int(remaining.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        let suffix = manager.lidClosedModeEnabled ? " · lid mode" : ""

        if hours > 0 {
            return String(format: "Active · %d:%02d:%02d remaining", hours, minutes, seconds) + suffix
        }
        return String(format: "Active · %d:%02d remaining", minutes, seconds) + suffix
    }
}
