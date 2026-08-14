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
        ScrollView(.vertical) {
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

                if let displayMessage = manager.displaySleepStatus {
                    Label(displayMessage, systemImage: "display")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()
                footer
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 400, height: 620)
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

            Toggle("Allow display to go dark", isOn: Binding(
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
                 ? "With the lid open, macOS may turn the display off normally while the system stays awake. With lid mode armed, closing the lid sets the built-in backlight to 0 instead of deliberately starting display sleep."
                 : "The app also prevents idle display sleep. In lid mode, the built-in brightness is left unchanged.")
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
                if manager.lidClosedModeEnabled {
                    Text(manager.kernelLidGuardActive ? "Kernel guard ON" : "Kernel guard OFF")
                        .font(.caption.monospaced())
                        .foregroundStyle(manager.kernelLidGuardActive ? .secondary : .red)
                } else if manager.sleepDisabledReadback {
                    Text("SleepDisabled = 1")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            if manager.lidClosedModeEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Label(manager.lidIsClosed ? "Lid closed" : "Lid open",
                              systemImage: manager.lidIsClosed ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                        if manager.hasExternalDisplay {
                            Text("· external display")
                        }
                    }

                    HStack(spacing: 6) {
                        Text(manager.sleepDisabledReadback ? "SleepDisabled=1" : "SleepDisabled=0")
                        Text("·")
                        Text(manager.kernelSelectorStatus)
                    }

                    if let causesSleep = manager.appleClamshellCausesSleep {
                        Text("AppleClamshellCausesSleep = \(causesSleep ? "Yes" : "No")")
                    }

                    if manager.backlightDimmed {
                        Text("Built-in backlight = 0")
                    }
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
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
                Text("Lid mode uses two layers: a direct kernel clamshell guard plus macOS SleepDisabled. One administrator approval is needed only for the two SleepDisabled pmset commands.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(manager.lidChanging ? "Installing…" : "Install Lid Authorization…") {
                    Task { await manager.installLidAuthorization() }
                }
                .disabled(manager.lidChanging)
            }

            Label("Safety: the screen can be dark while CPU, Wi-Fi and storage are still running. Do not use lid mode inside a bag, sleeve, or other poorly ventilated space.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Lock behavior")
                .font(.subheadline.weight(.semibold))

            Text("Closed-lid darkening now uses backlight brightness 0, so KeepAwakeMac does not intentionally start macOS's display-sleep password timer. With the lid open, normal macOS display sleep can still trigger your Lock Screen policy.")
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
            return manager.lidClosedModeEnabled
                ? "Active indefinitely · kernel lid guard armed"
                : "Active indefinitely"
        }

        let total = Int(remaining.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        let suffix = manager.lidClosedModeEnabled ? " · kernel lid guard" : ""

        if hours > 0 {
            return String(format: "Active · %d:%02d:%02d remaining", hours, minutes, seconds) + suffix
        }
        return String(format: "Active · %d:%02d remaining", minutes, seconds) + suffix
    }
}
