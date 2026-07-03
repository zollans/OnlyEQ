import SwiftUI
import UniformTypeIdentifiers

/// Three-tab import sheet: drop file, paste text, browse online (peqdb/AutoEq).
struct ImportSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable { case drop = "Drop file", paste = "Paste text", browse = "Browse online" }
    @State private var tab: Tab = .drop

    // Shared staged result.
    @State private var staged: PresetImporter.ImportResult?
    @State private var errorMessage: String?

    // Paste tab.
    @State private var pastedText = ""

    // Browse tab.
    @State private var searchText = ""
    @State private var source: OnlineEntry.Source = .peqdb
    @State private var selectedEntry: OnlineEntry?
    @State private var previewPreset: EQPreset?
    @State private var isFetchingPreview = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(12)

            Divider()

            Group {
                switch tab {
                case .drop: dropTab
                case .paste: pasteTab
                case .browse: browseTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(width: 560, height: 470)
        .task(id: source) {
            if tab == .browse { await state.onlineDB.load(source: source) }
        }
        .onChange(of: tab) { _, newTab in
            if newTab == .browse { Task { await state.onlineDB.load(source: source) } }
        }
    }

    // MARK: - Drop tab

    private var dropTab: some View {
        VStack(spacing: 14) {
            VStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text("Drop any EQ preset")
                    .font(.system(size: 15, weight: .semibold))
                Text("Drop a file here to import")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("Choose File…") { chooseFile() }
            }
            .frame(maxWidth: .infinity, minHeight: 200)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                    .foregroundStyle(.tertiary)
            )
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleDrop(providers)
            }

            VStack(spacing: 6) {
                Text("Supported formats").font(.system(size: 10)).foregroundStyle(.tertiary)
                FlowPills(items: ["AutoEq", "Equalizer APO", "peqdb", "Wavelet / GraphicEQ",
                                  "Poweramp JSON", "OPRA JSON", "Peace", "REW", "eqMac"])
            }

            stagedPreview
        }
        .padding(16)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            stage { try PresetImporter.importFile(at: url) }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async {
                stage { try PresetImporter.importFile(at: url) }
            }
        }
        return true
    }

    // MARK: - Paste tab

    private var pasteTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Paste EQ data or presets in any supported text format.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") {
                    pastedText = ""
                    staged = nil
                    errorMessage = nil
                }
                .controlSize(.small)
                .disabled(pastedText.isEmpty)
            }
            TextEditor(text: $pastedText)
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 150)
                .overlay(alignment: .topLeading) {
                    if pastedText.isEmpty {
                        Text("Preamp: -6.1 dB\nFilter 1: ON PK Fc 105 Hz Gain 6.4 dB Q 0.70")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 1).padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: pastedText) { _, text in
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        staged = nil
                        errorMessage = nil
                        return
                    }
                    stage(silent: true) { try PresetImporter.importText(text) }
                }
            stagedPreview
        }
        .padding(16)
    }

    // MARK: - Browse tab

    private var browseTab: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search \(source == .peqdb ? "peqdb" : "AutoEq") headphones…", text: $searchText)
                    .textFieldStyle(.plain)
                Picker("Source", selection: $source) {
                    ForEach(OnlineEntry.Source.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))

            if state.onlineDB.isLoading {
                Spacer()
                ProgressView("Loading database…")
                Spacer()
            } else if let error = state.onlineDB.error {
                Spacer()
                Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary)
                Spacer()
            } else {
                HSplitView {
                    resultsList
                    previewPane
                }
            }
        }
        .padding(12)
    }

    private var filteredEntries: [OnlineEntry] {
        let all = state.onlineDB.entries
        guard !searchText.isEmpty else { return Array(all.prefix(200)) }
        let terms = searchText.lowercased().split(separator: " ")
        return all.filter { entry in
            let haystack = "\(entry.model) \(entry.reviewer)".lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    private var resultsList: some View {
        List(filteredEntries, selection: Binding(
            get: { selectedEntry?.id },
            set: { id in
                selectedEntry = filteredEntries.first { $0.id == id }
                fetchPreview()
            }
        )) { entry in
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.model).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(entry.subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            .tag(entry.id)
        }
        .listStyle(.inset)
        .frame(minWidth: 220)
    }

    private var previewPane: some View {
        VStack(spacing: 8) {
            if isFetchingPreview {
                Spacer()
                ProgressView()
                Spacer()
            } else if let preview = previewPreset {
                Text(preview.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                EQCurveView(bands: preview.bands, preampDB: 0, showSpectrum: false)
                    .frame(height: 110)
                Grid(alignment: .leading, verticalSpacing: 3) {
                    GridRow {
                        Text("Preamp").foregroundStyle(.secondary)
                        Text(String(format: "%.1f dB", preview.preampDB))
                    }
                    GridRow {
                        Text("Filters").foregroundStyle(.secondary)
                        Text("\(preview.bands.count)")
                    }
                    GridRow {
                        Text("Source").foregroundStyle(.secondary)
                        Text(preview.source ?? "—")
                    }
                }
                .font(.system(size: 10))
                Spacer()
            } else {
                Spacer()
                Text("Select a headphone to preview its EQ")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .padding(10)
        .frame(minWidth: 180, maxWidth: .infinity)
    }

    private func fetchPreview() {
        guard let entry = selectedEntry else { return }
        isFetchingPreview = true
        previewPreset = nil
        errorMessage = nil
        Task {
            defer { isFetchingPreview = false }
            do {
                let preset = try await OnlineDatabase.fetchPreset(for: entry)
                previewPreset = preset
                staged = PresetImporter.ImportResult(preset: preset, detectedFormat: entry.source.rawValue)
            } catch {
                errorMessage = "Couldn’t fetch preset: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Shared preview + footer

    @ViewBuilder
    private var stagedPreview: some View {
        if let staged {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Live preview").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(staged.preset.bands.count) filters recognized · \(staged.detectedFormat)")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                EQCurveView(bands: staged.preset.bands, preampDB: 0, showSpectrum: false)
                    .frame(height: 80)
                ForEach(staged.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
        } else if let errorMessage {
            Label(errorMessage, systemImage: "xmark.octagon")
                .font(.system(size: 11)).foregroundStyle(.red)
        }
    }

    private var footer: some View {
        HStack {
            if staged != nil, tab == .browse {
                Button("Save as preset…") {
                    if let staged {
                        state.store.save(staged.preset)
                        state.apply(staged.preset)
                        dismiss()
                    }
                }
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Apply") {
                if let staged {
                    state.apply(staged.preset)
                    dismiss()
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(staged == nil)
        }
        .padding(12)
    }

    private func stage(silent: Bool = false, _ work: () throws -> PresetImporter.ImportResult) {
        do {
            staged = try work()
            errorMessage = nil
        } catch {
            staged = nil
            if !silent { errorMessage = error.localizedDescription }
        }
    }
}

/// Wrapping row of small gray capsule labels.
struct FlowPills: View {
    var items: [String]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(row, id: \.self) { item in
                        Text(item)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(.quaternary.opacity(0.6)))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var rows: [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        for (i, item) in items.enumerated() {
            current.append(item)
            if current.count == 5 || i == items.count - 1 {
                result.append(current)
                current = []
            }
        }
        return result
    }
}
