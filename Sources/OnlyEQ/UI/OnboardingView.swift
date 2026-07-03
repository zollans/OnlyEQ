import SwiftUI

/// First-launch onboarding: welcome → permission → pick headphones.
struct OnboardingView: View {
    @EnvironmentObject var state: AppState
    @State private var step = 0
    @State private var searchText = ""
    @State private var isApplying = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: permission
                default: pickHeadphones
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.bottom, 16)
        }
        .frame(width: 520, height: 440)
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 40))
                .foregroundStyle(.white)
                .frame(width: 88, height: 88)
                .background(RoundedRectangle(cornerRadius: 20).fill(Color.accentColor))
            Text("System-wide EQ\nfor your Mac")
                .font(.system(size: 24, weight: .bold))
                .multilineTextAlignment(.center)
            Text("Hear your music the way it was meant to sound.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Get Started") { step = 1 }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Spacer().frame(height: 8)
        }
        .padding(24)
    }

    private var permission: some View {
        VStack(spacing: 12) {
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "menubar.rectangle").font(.system(size: 26)).foregroundStyle(.secondary)
                Image(systemName: "record.circle").font(.system(size: 18)).foregroundStyle(.purple)
            }
            Text("Allow System Audio access")
                .font(.system(size: 20, weight: .bold))
            Text("macOS shows a recording indicator while EQ is active.\nAudio never leaves your Mac.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open System Settings") { PermissionHelper.openSystemSettings() }
                .buttonStyle(.borderedProminent)
            Button("I’ve enabled it →") { step = 2 }

            GroupBox {
                HStack(spacing: 8) {
                    if state.engineState == .running && !state.suspectedPermissionIssue {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Permission granted").font(.system(size: 12, weight: .medium))
                    } else {
                        ProgressView().controlSize(.small)
                        Text("Waiting… play some audio to confirm")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .padding(4)
            }
            .frame(width: 320)
            Spacer()
        }
        .padding(24)
        .onAppear {
            // Starting the engine triggers the system permission prompt.
            if !state.isEnabled { state.isEnabled = true } else { state.rebuildEngine() }
        }
    }

    private var pickHeadphones: some View {
        VStack(spacing: 10) {
            Text("Search your headphones\nto auto-EQ them")
                .font(.system(size: 20, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.top, 18)
            Text("We’ll import a preset tuned for your headphones.")
                .font(.system(size: 12)).foregroundStyle(.secondary)

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Sony WH-1000XM5", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
            .padding(.horizontal, 20)

            Group {
                if state.onlineDB.isLoading {
                    ProgressView().frame(maxHeight: .infinity)
                } else {
                    List(matches) { entry in
                        Button {
                            applyEntry(entry)
                        } label: {
                            HStack {
                                Image(systemName: "headphones").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.model).font(.system(size: 12, weight: .medium))
                                    Text(entry.subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.inset)
                }
            }
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 12)

            HStack {
                Button("Skip — start flat") { finish(apply: nil) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Start Listening") { finish(apply: nil) }
                    .buttonStyle(.borderedProminent)
                    .disabled(isApplying)
            }
            .padding(16)
        }
        .task { await state.onlineDB.load(source: .peqdb) }
    }

    private var matches: [OnlineEntry] {
        guard !searchText.isEmpty else { return Array(state.onlineDB.entries.prefix(50)) }
        let terms = searchText.lowercased().split(separator: " ")
        return state.onlineDB.entries.filter { entry in
            let haystack = "\(entry.model) \(entry.reviewer)".lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    private func applyEntry(_ entry: OnlineEntry) {
        isApplying = true
        Task {
            defer { isApplying = false }
            if let preset = try? await OnlineDatabase.fetchPreset(for: entry) {
                state.store.save(preset)
                finish(apply: preset)
            }
        }
    }

    private func finish(apply preset: EQPreset?) {
        if let preset { state.apply(preset) }
        UserDefaults.standard.set(true, forKey: "onboarded")
        WindowManager.shared.closeOnboarding()
    }
}
