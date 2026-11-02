import Foundation

/// Serializes a preset as Equalizer APO / AutoEq text (Gain and Q on every line
/// so `PresetImporter` can re-import it; Fc rounded to 2 decimals, others to 4;
/// `OFF … 0 dB` lines re-import as padding; left/right-only bands get APO
/// `Channel:` lines) or as OnlyEQ JSON with a fresh id.
enum PresetExporter {

    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        return f
    }()

    static func parametricText(_ preset: EQPreset) -> String {
        var lines = ["Preamp: \(format(preset.preampDB, minimumFractionDigits: 1)) dB"]
        // Equalizer APO `Channel:` lines apply to the filters below them; only
        // split presets need them, so other files stay byte-for-byte the same.
        var currentChannel = BandChannel.both
        for (i, band) in preset.bands.enumerated() {
            if band.channel != currentChannel {
                lines.append("Channel: \(channelToken(band.channel))")
                currentChannel = band.channel
            }
            let onOff = band.isEnabled ? "ON" : "OFF"
            lines.append("Filter \(i + 1): \(onOff) \(token(for: band.type)) Fc \(format(band.frequency, minimumFractionDigits: 0, maximumFractionDigits: 2)) Hz "
                         + "Gain \(format(band.gain, minimumFractionDigits: 1)) dB Q \(format(band.q, minimumFractionDigits: 2))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func json(_ preset: EQPreset) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var copy = preset
        copy.id = UUID()
        return try encoder.encode(copy)
    }

    private static func channelToken(_ channel: BandChannel) -> String {
        switch channel {
        case .both: "all"
        case .left: "L"
        case .right: "R"
        }
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

    private static func format(_ value: Double, minimumFractionDigits: Int, maximumFractionDigits: Int = 4) -> String {
        formatter.minimumFractionDigits = minimumFractionDigits
        formatter.maximumFractionDigits = maximumFractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
