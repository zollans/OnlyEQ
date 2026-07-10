import SwiftUI
import Combine
import AppKit
import QuartzCore

private struct ImportPresentation: Identifiable {
    let id = UUID()
    var profileSuggestion: ProfileSuggestion?
}

/// The EQ editor window: toolbar, interactive graph, band strip, bottom bar.
struct EditorView: View {
    static let importRequested = PassthroughSubject<ProfileSuggestion?, Never>()

    var initialImportRequested = false
    var initialProfileSuggestion: ProfileSuggestion?

    @EnvironmentObject var state: AppState
    @State private var selectedBandID: UUID?
    @State private var importPresentation: ImportPresentation?
    @State private var showSaveSheet = false
    @State private var saveName = ""
    @State private var handledInitialImport = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            graph
            bandStrip
            Divider()
            bottomBar
        }
        .sheet(item: $importPresentation) { presentation in
            ImportSheet(profileSuggestion: presentation.profileSuggestion).environmentObject(state)
        }
        .sheet(isPresented: $showSaveSheet) { saveSheet }
        .onReceive(Self.importRequested) { suggestion in
            importPresentation = ImportPresentation(profileSuggestion: suggestion)
        }
        .onAppear {
            guard initialImportRequested, !handledInitialImport else { return }
            handledInitialImport = true
            importPresentation = ImportPresentation(profileSuggestion: initialProfileSuggestion)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
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
                Text(state.preset.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .frame(maxWidth: 220)

            Button {
                saveName = state.preset.name
                showSaveSheet = true
            } label: {
                Image(systemName: "square.and.arrow.down.on.square")
            }
            .help("Save as preset")

            Spacer()

            Picker("", selection: Binding(
                get: { state.abSlot },
                set: { state.storeABAndSwitch(to: $0) }
            )) {
                Text("A").tag(0)
                Text("B").tag(1)
            }
            .pickerStyle(.segmented)
            .frame(width: 90)
            .help("A/B compare")

            Toggle("Bypass", isOn: $state.bypassed)
                .toggleStyle(.button)

            Spacer()

            Button {
                importPresentation = ImportPresentation(profileSuggestion: nil)
            } label: {
                Label("Import…", systemImage: "square.and.arrow.down")
            }

            Menu {
                ForEach(state.devices) { device in
                    Button(device.name) { state.selectOutputDevice(device) }
                }
            } label: {
                Text(state.currentDevice?.name ?? "No Device").font(.system(size: 12)).lineLimit(1)
            }
            .frame(maxWidth: 180)
        }
        .controlSize(.small)
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }

    // MARK: - Graph

    private var graph: some View {
        VStack(spacing: 3) {
            // The graph shows the EQ shape only — preamp is gain staging,
            // shown in the bottom bar, not baked into the curve.
            EQCurveView(
                bands: state.preset.bands,
                preampDB: 0,
                interactive: true,
                showSpectrum: state.isEnabled && state.editorIsVisible,
                showIndividualCurves: true,
                selectedBandID: $selectedBandID,
                onBandChange: { id, f, g in
                    guard let i = state.preset.bands.firstIndex(where: { $0.id == id }) else { return }
                    state.preset.bands[i].frequency = f
                    state.preset.bands[i].gain = g
                },
                onBandDragEnded: {
                    state.flushWorkingPresetPersistence()
                },
                onAddBand: { f, g in
                    guard state.preset.bands.count < 32 else { return }
                    let band = EQBand(type: .peak, frequency: f, gain: g, q: 1.41)
                    state.preset.bands.append(band)
                    selectedBandID = band.id
                }
            )
            .frame(minHeight: 220, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                Text("+12 dB").font(.system(size: 9)).foregroundStyle(.secondary).padding(4)
            }
            .overlay(alignment: .bottomLeading) {
                Text("−12 dB").font(.system(size: 9)).foregroundStyle(.secondary).padding(4)
            }
            .overlay(alignment: .topTrailing) {
                Label("Double-click graph to add band", systemImage: "plus.circle")
                    .font(.system(size: 10)).foregroundStyle(.tertiary).padding(4)
            }
            FrequencyAxisLabels()
        }
        .padding(.horizontal, 24)
        .padding(.top, 6)
    }

    // MARK: - Band strip

    private var bandStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(state.preset.bands.enumerated()), id: \.element.id) { index, band in
                    BandCard(index: index, band: bandBinding(band.id),
                             isSelected: selectedBandID == band.id,
                             onDelete: { state.preset.bands.removeAll { $0.id == band.id } })
                        .onTapGesture { selectedBandID = band.id }
                }
                Button {
                    state.preset.bands.append(EQBand(type: .peak, frequency: 1000, gain: 0, q: 1.41))
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16))
                        .frame(width: 44, height: 100)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                        .foregroundStyle(.tertiary)
                )
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
        }
        .frame(height: 122)
    }

    private func bandBinding(_ id: UUID) -> Binding<EQBand> {
        Binding(
            get: { state.preset.bands.first { $0.id == id } ?? EQBand() },
            set: { newValue in
                if let i = state.preset.bands.firstIndex(where: { $0.id == id }) {
                    state.preset.bands[i] = newValue
                }
            }
        )
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Text("Preamp").font(.system(size: 11)).foregroundStyle(.secondary)
            Text(String(format: "%.1f dB", state.effectivePreampDB))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .frame(width: 52, alignment: .trailing)
            Slider(value: Binding(
                get: { state.preset.preampDB },
                set: { state.preset.preampDB = ($0 * 10).rounded() / 10 }
            ), in: -20...0)
                .frame(width: 160)
                .disabled(state.autoPreampEnabled)
            Toggle("Auto", isOn: $state.autoPreampEnabled)
                .toggleStyle(.checkbox)
            clipIndicator
            Spacer()
            Toggle("Limiter", isOn: $state.limiterEnabled)
                .toggleStyle(AccentSwitchStyle(width: 30))
            Button("Reset") {
                state.applyFlat()
                selectedBandID = nil
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }

    private var clipIndicator: some View {
        PeakMeterView(processor: state.engine.processor, isActive: state.editorIsVisible)
            .frame(width: 78, height: 14)
    }

    private var saveSheet: some View {
        VStack(spacing: 12) {
            Text("Save Preset").font(.headline)
            TextField("Preset name", text: $saveName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
            HStack {
                Button("Cancel") { showSaveSheet = false }
                Button("Save") {
                    state.saveCurrentAsPreset(named: saveName.isEmpty ? "My Preset" : saveName)
                    showSaveSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saveName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }
}

/// Keeps the display-linked peak readout out of SwiftUI's view graph. Updating this
/// AppKit view redraws only its 78×14-point bounds instead of the editor.
private struct PeakMeterView: NSViewRepresentable {
    let processor: EQProcessor
    let isActive: Bool

    func makeNSView(context: Context) -> PeakMeterNSView {
        let view = PeakMeterNSView(processor: processor)
        view.setActive(isActive)
        return view
    }

    func updateNSView(_ view: PeakMeterNSView, context: Context) {
        view.setActive(isActive)
    }

    static func dismantleNSView(_ view: PeakMeterNSView, coordinator: ()) {
        view.stopAnimating()
    }
}

@MainActor
private final class PeakMeterNSView: NSView {
    private let processor: EQProcessor
    private let dotLayer = CAShapeLayer()
    private let textLayer = CATextLayer()
    private var animationLink: CADisplayLink?
    private var active = false
    private var db: Double = -60
    private var renderedLabel = ""
    private var renderedColor: NSColor?

    init(processor: EQProcessor) {
        self.processor = processor
        super.init(frame: .zero)
        wantsLayer = true
        dotLayer.actions = ["path": NSNull(), "fillColor": NSNull()]
        textLayer.actions = ["string": NSNull(), "foregroundColor": NSNull(),
                             "bounds": NSNull(), "position": NSNull()]
        textLayer.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        textLayer.fontSize = 10
        textLayer.alignmentMode = .left
        layer?.addSublayer(dotLayer)
        layer?.addSublayer(textLayer)
        updateLayers(force: true)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dotLayer.path = CGPath(ellipseIn: CGRect(x: 0, y: max((bounds.height - 7) / 2, 0),
                                                 width: 7, height: 7), transform: nil)
        textLayer.frame = CGRect(x: 11, y: 0, width: max(bounds.width - 11, 0), height: bounds.height)
        textLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    func setActive(_ active: Bool) {
        guard self.active != active else { return }
        self.active = active
        if active, window != nil {
            startAnimating()
        } else {
            stopAnimating()
            db = -60
            updateLayers(force: true)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if active, window != nil { startAnimating() } else { stopAnimating() }
    }

    private func updateLayers(force: Bool = false) {
        let color: NSColor = db > -0.1 ? .systemRed : (db > -3 ? .systemOrange : .systemGreen)
        let label = String(format: "%.1f dBFS", max(db, -60))
        guard force || label != renderedLabel || color != renderedColor else { return }
        renderedLabel = label
        renderedColor = color

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dotLayer.fillColor = color.cgColor
        textLayer.string = label
        textLayer.foregroundColor = NSColor.secondaryLabelColor.cgColor
        CATransaction.commit()
    }

    func stopAnimating() {
        animationLink?.invalidate()
        animationLink = nil
    }

    private func startAnimating() {
        guard animationLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(samplePeak(_:)))
        DisplayRefreshRate.configure(link, for: window)
        link.add(to: .main, forMode: .common)
        animationLink = link
        samplePeak(link)
    }

    @objc private func samplePeak(_ link: CADisplayLink) {
        let peak = processor.currentPeak
        db = peak > 0 ? 20 * log10(Double(peak)) : -60
        updateLayers()
    }

    deinit {
        animationLink?.invalidate()
    }
}

/// Compact per-band card: color dot, type menu, Fc/Gain/Q fields, delete.
struct BandCard: View {
    var index: Int
    @Binding var band: EQBand
    var isSelected: Bool
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(BandPalette.color(index)).frame(width: 8, height: 8)
                Text("\(index + 1)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Menu {
                    ForEach(FilterType.allCases) { type in
                        Button(type.displayName) { band.type = type }
                    }
                } label: {
                    Text(band.type.displayName).font(.system(size: 10))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer(minLength: 0)
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
            valueRow("Fc", value: $band.frequency, format: freqFormat, parse: parseFreq)
            valueRow("Gain", value: $band.gain, format: { String(format: "%.1f dB", $0) },
                     parse: { Double($0.replacingOccurrences(of: "dB", with: "").trimmingCharacters(in: .whitespaces)) })
            valueRow("Q", value: $band.q, format: { String(format: "%.2f", $0) }, parse: { Double($0) })
        }
        .padding(8)
        .frame(width: 150)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isSelected ? BandPalette.color(index) : Color(nsColor: .separatorColor),
                                      lineWidth: isSelected ? 1.5 : 1)
                )
        )
        .opacity(band.isEnabled ? 1 : 0.5)
        .contextMenu {
            Button(band.isEnabled ? "Disable Band" : "Enable Band") { band.isEnabled.toggle() }
            Button("Delete Band", role: .destructive) { onDelete() }
        }
    }

    private func freqFormat(_ f: Double) -> String {
        f >= 1000 ? String(format: "%.1f kHz", f / 1000) : String(format: "%.0f Hz", f)
    }

    private func parseFreq(_ s: String) -> Double? {
        let cleaned = s.lowercased().replacingOccurrences(of: "hz", with: "").trimmingCharacters(in: .whitespaces)
        if cleaned.hasSuffix("k") { return Double(cleaned.dropLast()).map { $0 * 1000 } }
        if s.lowercased().contains("khz") { return Double(cleaned.replacingOccurrences(of: "k", with: "")).map { $0 * 1000 } }
        return Double(cleaned)
    }

    private func valueRow(_ label: String, value: Binding<Double>,
                          format: @escaping (Double) -> String,
                          parse: @escaping (String) -> Double?) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
            EditableValueField(text: format(value.wrappedValue)) { input in
                if let parsed = parse(input) { value.wrappedValue = parsed }
            }
        }
    }
}

/// A tiny click-to-edit text field for band values.
struct EditableValueField: View {
    var text: String
    var onCommit: (String) -> Void

    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        if editing {
            TextField("", text: $draft, onCommit: {
                onCommit(draft)
                editing = false
            })
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 10).monospacedDigit())
            .frame(height: 18)
            .onExitCommand { editing = false }
        } else {
            Text(text)
                .font(.system(size: 10).monospacedDigit())
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.vertical, 2).padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.5)))
                .onTapGesture {
                    draft = text.components(separatedBy: " ").first ?? text
                    editing = true
                }
        }
    }
}
