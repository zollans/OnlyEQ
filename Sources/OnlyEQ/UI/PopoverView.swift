import SwiftUI

/// Rounded card used for every popover section (GroupBox renders as a flat
/// gray slab inside popovers, so we roll our own).
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                    )
            )
    }
}

/// Main menu-bar popover: header + master toggle, device card with boost
/// volume, preset card, curve preview, footer.
struct PopoverView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 10) {
            header
            Group {
                deviceCard
                presetCard
                if state.suspectedPermissionIssue {
                    permissionBanner
                } else {
                    curvePreview
                }
            }
            .disabled(!state.isEnabled)
            .opacity(state.isEnabled ? 1 : 0.45)
            footer
        }
        .padding(14)
        // Keep the host size stable when the permission banner replaces the
        // curve. AppDelegate can then size the popover once instead of asking
        // SwiftUI to propagate preferred-size changes on every spectrum frame.
        .frame(width: 360, height: 410, alignment: .top)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.accentColor))
            Text("OnlyEQ").font(.system(size: 13, weight: .semibold))
            Spacer()
            Toggle("", isOn: $state.isEnabled)
                .toggleStyle(AccentSwitchStyle())
                .labelsHidden()
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Device

    private var deviceCard: some View {
        Card {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: state.currentDevice?.icon ?? "speaker.slash")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.primary.opacity(0.07)))
                    Menu {
                        ForEach(state.devices) { device in
                            Button {
                                state.selectOutputDevice(device)
                            } label: {
                                if device.id == state.currentDevice?.id {
                                    Label(device.name, systemImage: "checkmark")
                                } else {
                                    Text(device.name)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(state.currentDevice?.name ?? "No Output Device")
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    Spacer(minLength: 0)
                }
                BoostSlider(value: $state.volumePercent, maxPercent: state.maxBoostPercent)
            }
        }
    }

    // MARK: - Preset

    private var presetCard: some View {
        Card {
            HStack(spacing: 8) {
                Text("Preset").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if state.presetWasAutoApplied {
                    Text("auto")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.22)))
                        .foregroundStyle(Color.accentColor)
                }
                Menu {
                    ForEach(state.store.allPresets) { preset in
                        Button(preset.name) { state.apply(preset) }
                    }
                    if !state.store.customPresets.isEmpty {
                        Divider()
                        Menu("Delete Preset") {
                            ForEach(state.store.customPresets) { preset in
                                Button(preset.name, role: .destructive) { state.store.delete(preset) }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(state.preset.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(maxWidth: 210)
                .fixedSize(horizontal: false, vertical: true)
                Button("Flat") { state.applyFlat() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Curve preview

    private var curvePreview: some View {
        Card {
            VStack(spacing: 5) {
                ZStack(alignment: .topTrailing) {
                    EQCurveView(bands: state.preset.bands, preampDB: 0,
                                showSpectrum: state.isEnabled && state.popoverIsVisible,
                                spectrumStyle: .subtle)
                        .frame(height: 116)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Button {
                        WindowManager.shared.showEditor()
                    } label: {
                        Label("Edit", systemImage: "pencil")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .padding(3)
                }
                FrequencyAxisLabels(compact: true)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { WindowManager.shared.showEditor() }
    }

    private var permissionBanner: some View {
        Card {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 5) {
                    Text("OnlyEQ needs System Audio access")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Allow OnlyEQ to capture system audio so it can apply EQ in real time.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open System Settings") { PermissionHelper.openSystemSettings() }
                        .controlSize(.small)
                        .padding(.top, 2)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                WindowManager.shared.showEditor(importing: true)
            } label: {
                Label("Import…", systemImage: "square.and.arrow.down")
                    .font(.system(size: 11))
            }
            Button {
                WindowManager.shared.showEditor()
            } label: {
                Label("Editor", systemImage: "slider.horizontal.3")
                    .font(.system(size: 11))
            }
            Button {
                WindowManager.shared.showSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            Spacer()
            statusIndicator
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 2)
    }

    private var statusIndicator: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        guard state.isEnabled else { return .secondary }
        switch state.engineState {
        case .running: return state.suspectedPermissionIssue ? .orange : .green
        case .stopped: return .secondary
        case .failed: return .red
        }
    }

    private var statusText: String {
        guard state.isEnabled else { return "Inactive" }
        switch state.engineState {
        case .running: return state.suspectedPermissionIssue ? "Waiting for audio" : "Active · \(state.latencyMilliseconds) ms"
        case .stopped: return "Inactive"
        case .failed: return "Error"
        }
    }
}

/// Volume slider: blue track to 100 %, orange boost zone beyond, tick at 100 %.
struct BoostSlider: View {
    @Binding var value: Double
    var maxPercent: Double
    @State private var trackedValue: Double?
    @State private var lastPublishedTime: TimeInterval = 0

    var body: some View {
        let displayedValue = trackedValue ?? value
        VStack(spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: displayedValue == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                GeometryReader { geo in
                    let width = geo.size.width
                    let fraction = min(max(displayedValue / maxPercent, 0), 1)
                    let hundred = min(100 / maxPercent, 1)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12)).frame(height: 5)
                        Capsule().fill(Color.accentColor)
                            .frame(width: min(fraction, hundred) * width, height: 5)
                        if displayedValue > 100 {
                            Rectangle().fill(.orange)
                                .frame(width: (fraction - hundred) * width, height: 5)
                                .offset(x: hundred * width)
                        }
                        // 100 % tick.
                        if maxPercent > 100 {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.primary.opacity(0.35))
                                .frame(width: 2, height: 9)
                                .offset(x: hundred * width - 1)
                        }
                        Circle()
                            .fill(.white)
                            .frame(width: 15, height: 15)
                            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                            .offset(x: fraction * (width - 15))
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            let updated = sliderValue(at: gesture.location.x, width: width)
                            trackedValue = updated
                            let now = ProcessInfo.processInfo.systemUptime
                            if lastPublishedTime == 0 || now - lastPublishedTime >= 1.0 / 60.0 {
                                value = updated
                                lastPublishedTime = now
                            }
                        }
                        .onEnded { gesture in
                            let updated = sliderValue(at: gesture.location.x, width: width)
                            value = updated
                            trackedValue = nil
                            lastPublishedTime = 0
                        })
                }
                .frame(height: 18)
            }
            GeometryReader { geo in
                let width = geo.size.width
                let hundred = min(100 / maxPercent, 1)
                ZStack(alignment: .topLeading) {
                    Text("0%").offset(x: 0)
                    Text("100%").offset(x: hundred * width - 12)
                    Text("\(Int(maxPercent))%").offset(x: width - 26)
                }
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            }
            .frame(height: 11)
            .padding(.leading, 24)
        }
    }

    private func sliderValue(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 15 else { return value }
        return min(max(Double((x - 7.5) / (width - 15)) * maxPercent, 0), maxPercent)
    }
}

enum PermissionHelper {
    static func openSystemSettings() {
        // Privacy & Security → Screen & System Audio Recording.
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
        NSWorkspace.shared.open(url)
    }
}
