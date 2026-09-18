import Foundation

/// Serializes a preset as Equalizer APO / AutoEq parametric text, the inverse
/// of `PresetImporter.parseParametricText`. Gain and Q are always written so
/// the output re-imports unchanged.
enum PresetExporter {

    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.maximumFractionDigits = 4
        return f
    }()

    static func parametricText(_ preset: EQPreset) -> String {
        var lines = ["Preamp: \(format(preset.preampDB, minimumFractionDigits: 1)) dB"]
        for (i, band) in preset.bands.enumerated() {
            let onOff = band.isEnabled ? "ON" : "OFF"
            lines.append("Filter \(i + 1): \(onOff) \(token(for: band.type)) Fc \(format(band.frequency, minimumFractionDigits: 0)) Hz "
                         + "Gain \(format(band.gain, minimumFractionDigits: 1)) dB Q \(format(band.q, minimumFractionDigits: 2))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func token(for type: FilterType) -> String {
        switch type {
        case .peak: "PK"
        case .lowShelf: "LSC"
        case .highShelf: "HSC"
        case .lowPass: "LPQ"
        case .highPass: "HPQ"
        case .bandPass: "BP"
        case .notch: "NO"
        }
    }

    private static func format(_ value: Double, minimumFractionDigits: Int) -> String {
        formatter.minimumFractionDigits = minimumFractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
