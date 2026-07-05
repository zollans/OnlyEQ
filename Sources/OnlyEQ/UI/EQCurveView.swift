import SwiftUI

enum BandPalette {
    static let colors: [Color] = [.blue, .teal, .purple, .pink, .orange, .green, .indigo, .mint, .red, .cyan]
    static func color(_ index: Int) -> Color { colors[index % colors.count] }
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
    var onAddBand: ((_ frequency: Double, _ gain: Double) -> Void)?

    private let minF = 20.0, maxF = 20000.0

    init(bands: [EQBand], preampDB: Double, interactive: Bool = false, showSpectrum: Bool = true,
         spectrumStyle: SpectrumStyle = .normal,
         showIndividualCurves: Bool = false, rangeDB: Double = 12,
         selectedBandID: Binding<UUID?> = .constant(nil),
         onBandChange: ((UUID, Double, Double) -> Void)? = nil,
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
        self.onAddBand = onAddBand
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                gridLayer(size: size)
                if showSpectrum { SpectrumBarsView(style: spectrumStyle, size: size) }
                curveLayer(size: size)
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

    private func curvePoints(size: CGSize) -> [CGPoint] {
        let freqs = EQResponse.logGrid(count: 128)
        let response = EQResponse.curve(bands: bands, preampDB: preampDB, frequencies: freqs)
        return zip(freqs, response).map { CGPoint(x: x(forFrequency: $0, size), y: y(forDB: min(max($1, -rangeDB), rangeDB), size)) }
    }

    @ViewBuilder
    private func curveLayer(size: CGSize) -> some View {
        Canvas { ctx, _ in
            // Individual band curves (editor only).
            if showIndividualCurves {
                let freqs = EQResponse.logGrid(count: 96)
                for (i, band) in bands.enumerated() where band.isEnabled {
                    let response = EQResponse.curve(bands: [band], preampDB: 0, frequencies: freqs)
                    var path = Path()
                    for (j, f) in freqs.enumerated() {
                        let p = CGPoint(x: x(forFrequency: f, size), y: y(forDB: min(max(response[j], -rangeDB), rangeDB), size))
                        if j == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                    ctx.stroke(path, with: .color(BandPalette.color(i).opacity(0.22)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }

            let points = curvePoints(size: size)
            guard points.count > 1 else { return }

            var fill = Path()
            fill.move(to: CGPoint(x: points[0].x, y: size.height))
            for p in points { fill.addLine(to: p) }
            fill.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(
                Gradient(colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.03)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
            ))

            var stroke = Path()
            stroke.move(to: points[0])
            for p in points.dropFirst() { stroke.addLine(to: p) }
            ctx.stroke(stroke, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        }
    }

    @ViewBuilder
    private func nodeLayer(size: CGSize) -> some View {
        ForEach(Array(bands.enumerated()), id: \.element.id) { index, band in
            let isSelected = selectedBandID == band.id
            Circle()
                .fill(BandPalette.color(index))
                .frame(width: isSelected ? 14 : 11, height: isSelected ? 14 : 11)
                .overlay(Circle().stroke(.white.opacity(isSelected ? 0.9 : 0.5), lineWidth: isSelected ? 2 : 1))
                .opacity(band.isEnabled ? 1 : 0.35)
                .position(x: x(forFrequency: band.frequency, size),
                          y: y(forDB: min(max(band.gain, -rangeDB), rangeDB), size))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            selectedBandID = band.id
                            let f = min(max(frequency(atX: value.location.x, size), minF), maxF)
                            let g = min(max(dB(atY: value.location.y, size), -rangeDB), rangeDB)
                            onBandChange?(band.id, f, (g * 10).rounded() / 10)
                        }
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

/// Live spectrum bars in their own TimelineView-driven Canvas: the periodic
/// refresh redraws only this layer, instead of re-evaluating the whole curve
/// view (grid, response curve, drag nodes) 20× per second like the old
/// Timer + @State approach did.
private struct SpectrumBarsView: View {
    var style: EQCurveView.SpectrumStyle
    var size: CGSize

    private let spectrum = AppState.shared.engine.spectrum

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 20)) { timeline in
            // Read the date and capture it in the Canvas closure — otherwise
            // SwiftUI sees no dependency on the schedule and never redraws.
            let date = timeline.date
            Canvas { ctx, _ in
                _ = date
                let bars = spectrum.bars()
                guard !bars.isEmpty else { return }
                let barWidth = size.width / CGFloat(bars.count)
                for (i, level) in bars.enumerated() {
                    let h = CGFloat(level) * size.height * style.heightScale
                    let rect = CGRect(x: CGFloat(i) * barWidth + 1, y: size.height - h,
                                      width: max(barWidth - 2, 1), height: h)
                    ctx.fill(Path(rect), with: .color(.secondary.opacity(style.opacity)))
                }
            }
        }
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
