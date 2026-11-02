import SwiftUI
import AppKit
import QuartzCore

enum BandPalette {
    static let colors: [Color] = [.blue, .teal, .purple, .pink, .orange, .green, .indigo, .mint, .red, .cyan]
    static func color(_ index: Int) -> Color { colors[index % colors.count] }
}

/// Left and right curve colors for presets with one-sided bands.
enum ChannelPalette {
    static func color(_ channel: BandChannel) -> Color {
        switch channel {
        case .left: Color(red: 0.25, green: 0.85, blue: 0.78)
        case .right: Color(red: 1.0, green: 0.42, blue: 0.36)
        case .both: .accentColor
        }
    }

    typealias RGB = (r: Double, g: Double, b: Double)

    /// sRGB blend between two resolved colors (`Color.mix` needs macOS 15).
    static func blend(_ a: RGB, _ b: RGB, _ t: Double) -> Color {
        Color(red: a.r + (b.r - a.r) * t, green: a.g + (b.g - a.g) * t, blue: a.b + (b.b - a.b) * t)
    }

    static func rgb(_ channel: BandChannel) -> (r: Double, g: Double, b: Double) {
        let c = NSColor(color(channel)).usingColorSpace(.sRGB) ?? .systemBlue
        return (c.redComponent, c.greenComponent, c.blueComponent)
    }
}

/// Frequency responses depend on filter parameters, not view dimensions. Keep
/// them stable across live-resize frames and recompute only bands that changed.
@MainActor
private final class EQCurveResponseCache: ObservableObject {
    struct Data {
        var combinedFrequencies: [Double]
        var combinedResponse: [Double]
        /// Set when the preset has one-sided bands; `combinedResponse` is then
        /// the left channel.
        var rightResponse: [Double]?
        var individualFrequencies: [Double]
        var individualResponses: [(index: Int, response: [Double])]
    }

    private static let combinedFrequencies = EQResponse.logGrid(count: 256)
    private static let individualFrequencies = EQResponse.logGrid(count: 96)
    private var cachedBands: [EQBand] = []
    private var cachedPreampDB = Double.nan
    private var cachedCombined: [Double] = []
    private var cachedRight: [Double]?
    private var individualBands: [EQBand] = []
    private var individualResponses: [[Double]] = []

    func data(bands: [EQBand], preampDB: Double, includeIndividuals: Bool) -> Data {
        if bands != cachedBands || preampDB != cachedPreampDB {
            cachedBands = bands
            cachedPreampDB = preampDB
            let split = bands.contains { $0.channel != .both }
            cachedCombined = EQResponse.curve(
                bands: bands, preampDB: preampDB, frequencies: Self.combinedFrequencies, channel: split ? 0 : nil
            )
            cachedRight = split
                ? EQResponse.curve(bands: bands, preampDB: preampDB, frequencies: Self.combinedFrequencies, channel: 1)
                : nil
        }

        var enabledResponses: [(index: Int, response: [Double])] = []
        if includeIndividuals {
            if individualBands.count != bands.count {
                individualBands = bands
                individualResponses = bands.map {
                    EQResponse.curve(bands: [$0], preampDB: 0, frequencies: Self.individualFrequencies)
                }
            } else {
                for index in bands.indices where bands[index] != individualBands[index] {
                    individualBands[index] = bands[index]
                    individualResponses[index] = EQResponse.curve(
                        bands: [bands[index]], preampDB: 0, frequencies: Self.individualFrequencies
                    )
                }
            }
            enabledResponses = bands.indices.compactMap { index in
                bands[index].isEnabled ? (index, individualResponses[index]) : nil
            }
        }

        return Data(
            combinedFrequencies: Self.combinedFrequencies,
            combinedResponse: cachedCombined,
            rightResponse: cachedRight,
            individualFrequencies: Self.individualFrequencies,
            individualResponses: enabledResponses
        )
    }
}

/// The hero EQ curve: log-frequency response with optional live spectrum bars
/// behind it and optional draggable band nodes (editor mode).
struct EQCurveView: View {
    enum SpectrumStyle {
        case normal, subtle

        var opacity: Double { self == .subtle ? 0.08 : 0.10 }
        var heightScale: Double { self == .subtle ? 0.6 : 0.75 }
    }

    var bands: [EQBand]
    var preampDB: Double
    var interactive = false
    var showSpectrum = true
    var spectrumStyle: SpectrumStyle = .normal
    var showIndividualCurves = false
    var rangeDB: Double = 12
    @Binding var selectedBandID: UUID?
    var onBandChange: ((UUID, _ frequency: Double, _ gain: Double) -> Void)?
    var onBandDragEnded: (() -> Void)?
    var onAddBand: ((_ frequency: Double, _ gain: Double) -> Void)?
    @StateObject private var responseCache = EQCurveResponseCache()

    private let minF = 20.0, maxF = 20000.0

    init(bands: [EQBand], preampDB: Double, interactive: Bool = false, showSpectrum: Bool = true,
         spectrumStyle: SpectrumStyle = .normal,
         showIndividualCurves: Bool = false, rangeDB: Double = 12,
         selectedBandID: Binding<UUID?> = .constant(nil),
         onBandChange: ((UUID, Double, Double) -> Void)? = nil,
         onBandDragEnded: (() -> Void)? = nil,
         onAddBand: ((Double, Double) -> Void)? = nil) {
        self.bands = bands
        self.preampDB = preampDB
        self.interactive = interactive
        self.showSpectrum = showSpectrum
        self.spectrumStyle = spectrumStyle
        self.showIndividualCurves = showIndividualCurves
        self.rangeDB = rangeDB
        self._selectedBandID = selectedBandID
        self.onBandChange = onBandChange
        self.onBandDragEnded = onBandDragEnded
        self.onAddBand = onAddBand
    }

    var body: some View {
        let responseData = responseCache.data(
            bands: bands, preampDB: preampDB, includeIndividuals: showIndividualCurves
        )
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                gridLayer(size: size)
                if showSpectrum { SpectrumBarsView(style: spectrumStyle) }
                curveLayer(size: size, data: responseData)
                if interactive { nodeLayer(size: size) }
            }
            .contentShape(Rectangle())
            .gesture(interactive ? doubleClickGesture(size: size) : nil)
        }
    }

    // MARK: - Coordinate mapping

    private func x(forFrequency f: Double, _ size: CGSize) -> CGFloat {
        CGFloat((log10(f) - log10(minF)) / (log10(maxF) - log10(minF))) * size.width
    }

    private func frequency(atX x: CGFloat, _ size: CGSize) -> Double {
        pow(10, log10(minF) + Double(x / size.width) * (log10(maxF) - log10(minF)))
    }

    private func y(forDB db: Double, _ size: CGSize) -> CGFloat {
        CGFloat(0.5 - db / (rangeDB * 2)) * size.height
    }

    private func dB(atY y: CGFloat, _ size: CGSize) -> Double {
        (0.5 - Double(y / size.height)) * rangeDB * 2
    }

    // MARK: - Layers

    @ViewBuilder
    private func gridLayer(size: CGSize) -> some View {
        Canvas { ctx, _ in
            // Octave grid lines.
            for f in [31.0, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000] {
                let gx = x(forFrequency: f, size)
                var path = Path()
                path.move(to: CGPoint(x: gx, y: 0))
                path.addLine(to: CGPoint(x: gx, y: size.height))
                ctx.stroke(path, with: .color(.secondary.opacity(0.12)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            // 0 dB center line.
            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: y(forDB: 0, size)))
            zero.addLine(to: CGPoint(x: size.width, y: y(forDB: 0, size)))
            ctx.stroke(zero, with: .color(.secondary.opacity(0.25)), lineWidth: 1)
        }
    }

    private func curvePoints(size: CGSize, frequencies: [Double], response: [Double]) -> [CGPoint] {
        zip(frequencies, response).map {
            CGPoint(x: x(forFrequency: $0, size),
                    y: y(forDB: min(max($1, -rangeDB), rangeDB), size))
        }
    }

    /// Catmull-Rom spline through the sampled response, so sharp peaks read
    /// as curves rather than polylines. The grid is dense enough that the
    /// spline's overshoot stays well under a pixel.
    private func smoothPath(_ points: [CGPoint], into path: inout Path) {
        guard points.count > 1 else { return }
        for i in 0..<(points.count - 1) {
            let p0 = points[max(i - 1, 0)], p1 = points[i]
            let p2 = points[i + 1], p3 = points[min(i + 2, points.count - 1)]
            path.addCurve(to: p2,
                          control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
    }

    /// Horizontal gradient for one channel's curve: the shared color where both
    /// channels agree, fading to the channel's color where they diverge.
    private func divergenceGradient(left: [Double], right: [Double], frequencies: [Double],
                                    channel: BandChannel) -> Gradient {
        let shared = ChannelPalette.color(.both), own = ChannelPalette.color(channel)
        let sharedRGB = ChannelPalette.rgb(.both), ownRGB = ChannelPalette.rgb(channel)
        var stops: [Gradient.Stop] = []
        var lastT = -1.0
        let span = log10(maxF) - log10(minF)
        for i in frequencies.indices {
            // Fully the channel's color once the curves are ~0.5 dB apart.
            let t = min(max((abs(left[i] - right[i]) - 0.05) / 0.45, 0), 1)
            guard abs(t - lastT) > 0.02 || i == frequencies.count - 1 else { continue }
            lastT = t
            let location = (log10(frequencies[i]) - log10(minF)) / span
            stops.append(.init(color: t == 0 ? shared : t == 1 ? own : ChannelPalette.blend(sharedRGB, ownRGB, t),
                               location: min(max(location, 0), 1)))
        }
        return Gradient(stops: stops)
    }

    @ViewBuilder
    private func curveLayer(size: CGSize, data: EQCurveResponseCache.Data) -> some View {
        Canvas { ctx, _ in
            // Individual band curves (editor only).
            if showIndividualCurves {
                let selectedIndex = bands.firstIndex { $0.id == selectedBandID }
                for item in data.individualResponses {
                    var path = Path()
                    let points = curvePoints(size: size, frequencies: data.individualFrequencies, response: item.response)
                    guard let first = points.first else { continue }
                    path.move(to: first)
                    smoothPath(points, into: &path)
                    let color = BandPalette.color(item.index)
                    if item.index == selectedIndex {
                        // The selected band's own shape, filled to the 0 dB line,
                        // trimmed to where it acts so it doesn't tint the zero line.
                        guard let lo = item.response.firstIndex(where: { abs($0) > 0.05 }),
                              let hi = item.response.lastIndex(where: { abs($0) > 0.05 }) else { continue }
                        let active = Array(points[max(lo - 1, 0)...min(hi + 1, points.count - 1)])
                        var shape = Path()
                        shape.move(to: active[0])
                        smoothPath(active, into: &shape)
                        var area = shape
                        area.addLine(to: CGPoint(x: active[active.count - 1].x, y: y(forDB: 0, size)))
                        area.addLine(to: CGPoint(x: active[0].x, y: y(forDB: 0, size)))
                        area.closeSubpath()
                        ctx.fill(area, with: .color(color.opacity(0.10)))
                        ctx.stroke(shape, with: .color(color.opacity(0.55)), lineWidth: 1)
                    } else {
                        ctx.stroke(path, with: .color(color.opacity(0.13)),
                                   style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                }
            }

            let points = curvePoints(size: size, frequencies: data.combinedFrequencies, response: data.combinedResponse)
            guard points.count > 1 else { return }
            let rightPoints = data.rightResponse.map {
                curvePoints(size: size, frequencies: data.combinedFrequencies, response: $0)
            }

            // One fill, under the higher curve when left and right differ.
            let top = rightPoints.map { right in zip(points, right).map { CGPoint(x: $0.x, y: min($0.y, $1.y)) } } ?? points
            var fill = Path()
            fill.move(to: CGPoint(x: top[0].x, y: size.height))
            fill.addLine(to: top[0])
            smoothPath(top, into: &fill)
            fill.addLine(to: CGPoint(x: top[top.count - 1].x, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(
                Gradient(colors: [Color.accentColor.opacity(0.32), Color.accentColor.opacity(0.02)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
            ))

            let style = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            guard let rightPoints, let right = data.rightResponse else {
                var stroke = Path()
                stroke.move(to: points[0])
                smoothPath(points, into: &stroke)
                ctx.stroke(stroke, with: .color(.accentColor), style: style)
                return
            }

            // Split preset: both curves are drawn in full. Where the channels
            // get the same EQ they coincide in the shared color; each fades to
            // its own color only where they part.
            let left = data.combinedResponse
            for (channel, channelPoints) in [(BandChannel.right, rightPoints), (.left, points)] {
                var stroke = Path()
                stroke.move(to: channelPoints[0])
                smoothPath(channelPoints, into: &stroke)
                let gradient = divergenceGradient(left: left, right: right,
                                                  frequencies: data.combinedFrequencies, channel: channel)
                ctx.stroke(stroke, with: .linearGradient(gradient, startPoint: .zero,
                                                         endPoint: CGPoint(x: size.width, y: 0)),
                           style: style)
            }
        }
    }

    @ViewBuilder
    private func nodeLayer(size: CGSize) -> some View {
        ForEach(Array(bands.enumerated()), id: \.element.id) { index, band in
            DraggableBandNode(
                index: index,
                band: band,
                size: size,
                rangeDB: rangeDB,
                selectedBandID: $selectedBandID,
                onChange: onBandChange,
                onEnded: onBandDragEnded
            )
        }
    }

    private func doubleClickGesture(size: CGSize) -> some Gesture {
        SpatialTapGesture(count: 2).onEnded { value in
            let f = min(max(frequency(atX: value.location.x, size), minF), maxF)
            let g = min(max(dB(atY: value.location.y, size), -rangeDB), rangeDB)
            onAddBand?((f * 10).rounded() / 10, (g * 10).rounded() / 10)
        }
    }
}

/// Hosts the animated spectrum in an AppKit layer. Updating the layer's path
/// does not invalidate SwiftUI's editor graph or trigger a window layout pass.
private struct SpectrumBarsView: NSViewRepresentable {
    var style: EQCurveView.SpectrumStyle

    func makeNSView(context: Context) -> SpectrumBarsNSView {
        let view = SpectrumBarsNSView(spectrum: AppState.shared.engine.spectrum)
        view.configure(style: style)
        return view
    }

    func updateNSView(_ view: SpectrumBarsNSView, context: Context) {
        view.configure(style: style)
    }

    static func dismantleNSView(_ view: SpectrumBarsNSView, coordinator: ()) {
        view.stopAnimating()
    }
}

@MainActor
private final class SpectrumBarsNSView: NSView {
    private let spectrum: SpectrumAnalyzer
    private let barsLayer = CAShapeLayer()
    private var animationLink: CADisplayLink?
    private var targetBars = [Float](repeating: 0, count: SpectrumAnalyzer.barCount)
    private var displayedBars = [Float](repeating: 0, count: SpectrumAnalyzer.barCount)
    private var lastAnalysisTime: CFTimeInterval = 0
    private var barOpacity = 0.10
    private var heightScale = 0.75
    private var configuredStyle: EQCurveView.SpectrumStyle?

    init(spectrum: SpectrumAnalyzer) {
        self.spectrum = spectrum
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        barsLayer.actions = ["path": NSNull(), "fillColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(barsLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(style: EQCurveView.SpectrumStyle) {
        guard configuredStyle != style else { return }
        configuredStyle = style
        barOpacity = style.opacity
        heightScale = style.heightScale
        updateColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopAnimating() } else { startAnimating() }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        barsLayer.frame = bounds
        CATransaction.commit()
        renderBars(displayedBars)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    func stopAnimating() {
        animationLink?.invalidate()
        animationLink = nil
    }

    private func startAnimating() {
        guard animationLink == nil else { return }
        targetBars.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        displayedBars.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        lastAnalysisTime = 0

        let link = displayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
        DisplayRefreshRate.configure(link, for: window)
        link.add(to: .main, forMode: .common)
        animationLink = link
        renderBars(displayedBars)
    }

    private func updateColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        barsLayer.fillColor = NSColor.secondaryLabelColor.withAlphaComponent(barOpacity).cgColor
        CATransaction.commit()
    }

    @objc private func displayLinkDidFire(_ link: CADisplayLink) {
        // FFT/magnitude work stays capped at 30 Hz. The layer interpolates the
        // latest targets at the screen refresh rate without multiplying DSP.
        if lastAnalysisTime == 0 || link.timestamp - lastAnalysisTime >= 1.0 / 30.0 {
            let bars = spectrum.bars()
            if bars.count == targetBars.count {
                for index in bars.indices { targetBars[index] = bars[index] }
            }
            lastAnalysisTime = link.timestamp
        }

        let duration = max(link.duration, 1.0 / 120.0)
        let blend = Float(1 - exp(-duration / 0.045))
        var changed = false
        for index in displayedBars.indices {
            let delta = targetBars[index] - displayedBars[index]
            if abs(delta) > 0.0005 {
                displayedBars[index] += delta * blend
                changed = true
            } else {
                displayedBars[index] = targetBars[index]
            }
        }
        if changed { renderBars(displayedBars) }
    }

    private func renderBars(_ bars: [Float]) {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        guard !bars.isEmpty else { return }

        let barWidth = size.width / CGFloat(bars.count)
        let path = CGMutablePath()
        for (index, level) in bars.enumerated() {
            let height = CGFloat(level) * size.height * heightScale
            path.addRect(CGRect(x: CGFloat(index) * barWidth + 1, y: 0,
                                width: max(barWidth - 2, 1), height: height))
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        barsLayer.path = path
        CATransaction.commit()
    }

    deinit {
        animationLink?.invalidate()
    }
}

/// Keeps pointer tracking local to a single node. The node follows every mouse
/// event immediately, while model/audio updates are capped at the display rate
/// so a high-polling-rate mouse cannot rebuild the entire editor hundreds of
/// times per second.
private struct DraggableBandNode: View {
    let index: Int
    let band: EQBand
    let size: CGSize
    let rangeDB: Double
    @Binding var selectedBandID: UUID?
    let onChange: ((UUID, Double, Double) -> Void)?
    let onEnded: (() -> Void)?

    @State private var dragPosition: CGPoint?
    @State private var lastModelUpdate: CFTimeInterval = 0
    @State private var modelUpdateInterval: TimeInterval = 1.0 / 60.0

    private let minF = 20.0, maxF = 20000.0

    var body: some View {
        let isSelected = selectedBandID == band.id
        Circle()
            .fill(BandPalette.color(index))
            .frame(width: isSelected ? 14 : 11, height: isSelected ? 14 : 11)
            .overlay(Circle().stroke(.white.opacity(isSelected ? 0.9 : 0.5),
                                     lineWidth: isSelected ? 2 : 1))
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .overlay(alignment: .topTrailing) {
                if band.channel != .both {
                    Text(band.channel == .left ? "L" : "R")
                        .font(.system(size: 7, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 11, height: 11)
                        .background(Circle().fill(ChannelPalette.color(band.channel)))
                        .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 0.5))
                        .fixedSize()
                        .offset(x: 8, y: -8)
                        .allowsHitTesting(false)
                }
            }
            .opacity(band.isEnabled ? 1 : 0.35)
            .position(dragPosition ?? CGPoint(x: x(forFrequency: band.frequency),
                                              y: y(forDB: band.gain)))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if selectedBandID != band.id { selectedBandID = band.id }
                    let update = mapped(value.location)
                    dragPosition = update.position

                    let now = CACurrentMediaTime()
                    if lastModelUpdate == 0 {
                        modelUpdateInterval = DisplayRefreshRate.interval()
                    }
                    if lastModelUpdate == 0 || now - lastModelUpdate >= modelUpdateInterval {
                        onChange?(band.id, update.frequency, update.gain)
                        lastModelUpdate = now
                    }
                }
                .onEnded { value in
                    let update = mapped(value.location)
                    onChange?(band.id, update.frequency, update.gain)
                    dragPosition = nil
                    lastModelUpdate = 0
                    onEnded?()
                })
    }

    private func x(forFrequency frequency: Double) -> CGFloat {
        CGFloat((log10(frequency) - log10(minF)) / (log10(maxF) - log10(minF))) * size.width
    }

    private func y(forDB db: Double) -> CGFloat {
        CGFloat(0.5 - min(max(db, -rangeDB), rangeDB) / (rangeDB * 2)) * size.height
    }

    private func mapped(_ location: CGPoint) -> (position: CGPoint, frequency: Double, gain: Double) {
        let px = min(max(location.x, 0), size.width)
        let py = min(max(location.y, 0), size.height)
        let frequency = pow(10, log10(minF) + Double(px / size.width) * (log10(maxF) - log10(minF)))
        let rawGain = (0.5 - Double(py / size.height)) * rangeDB * 2
        let gain = (min(max(rawGain, -rangeDB), rangeDB) * 10).rounded() / 10
        return (CGPoint(x: px, y: py), frequency, gain)
    }
}

/// Axis labels under curve views, placed at their true log-scale positions so
/// they line up with the octave gridlines.
struct FrequencyAxisLabels: View {
    var compact = false

    private var items: [(freq: Double, label: String)] {
        compact
            ? [(20, "20 Hz"), (100, "100 Hz"), (1000, "1 kHz"), (10000, "10 kHz")]
            : [(20, "20 Hz"), (62, "62"), (125, "125"), (250, "250"), (500, "500"),
               (1000, "1 kHz"), (2000, "2 kHz"), (4000, "4 kHz"), (8000, "8 kHz"), (16000, "16 kHz")]
    }

    var body: some View {
        GeometryReader { geo in
            ForEach(items, id: \.label) { item in
                let x = CGFloat((log10(item.freq) - log10(20.0)) / (log10(20000.0) - log10(20.0))) * geo.size.width
                Text(item.label)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .position(x: min(max(x, 14), geo.size.width - 16), y: geo.size.height / 2)
            }
        }
        .frame(height: 12)
    }
}
