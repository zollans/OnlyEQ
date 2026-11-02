import Foundation

enum FilterType: String, Codable, CaseIterable, Identifiable {
    case peak, lowShelf, highShelf, lowPass, highPass, notch, bandPass

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .peak: "Peak"
        case .lowShelf: "Low Shelf"
        case .highShelf: "High Shelf"
        case .lowPass: "Low Pass"
        case .highPass: "High Pass"
        case .notch: "Notch"
        case .bandPass: "Band Pass"
        }
    }
}

/// Which output channel a band filters. `both` is the default and is what every
/// preset used before per-channel EQ, so it is omitted from saved JSON.
enum BandChannel: String, Codable, CaseIterable, Identifiable {
    case both, left, right

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .both: "Both"
        case .left: "Left"
        case .right: "Right"
        }
    }

    /// Channel index 0 is left and 1 is right; any further channels only get
    /// bands that apply to both.
    func applies(toChannel index: Int) -> Bool {
        switch self {
        case .both: true
        case .left: index == 0
        case .right: index == 1
        }
    }
}

struct EQBand: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var type: FilterType = .peak
    var frequency: Double = 1000
    var gain: Double = 0
    var q: Double = 1.41
    var isEnabled = true
    var channel: BandChannel = .both

    private enum CodingKeys: String, CodingKey { case type, frequency, gain, q, isEnabled, channel }

    init(type: FilterType = .peak, frequency: Double = 1000, gain: Double = 0, q: Double = 1.41,
         isEnabled: Bool = true, channel: BandChannel = .both) {
        self.type = type
        self.frequency = frequency
        self.gain = gain
        self.q = q
        self.isEnabled = isEnabled
        self.channel = channel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(FilterType.self, forKey: .type) ?? .peak
        frequency = try c.decode(Double.self, forKey: .frequency)
        gain = try c.decodeIfPresent(Double.self, forKey: .gain) ?? 0
        q = try c.decodeIfPresent(Double.self, forKey: .q) ?? 1.41
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        channel = try c.decodeIfPresent(BandChannel.self, forKey: .channel) ?? .both
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(frequency, forKey: .frequency)
        try c.encode(gain, forKey: .gain)
        try c.encode(q, forKey: .q)
        try c.encode(isEnabled, forKey: .isEnabled)
        if channel != .both { try c.encode(channel, forKey: .channel) }
    }

    // `id` is a runtime identity for SwiftUI, not part of the value — it isn't
    // encoded, so equality/hashing must ignore it too.
    static func == (lhs: EQBand, rhs: EQBand) -> Bool {
        lhs.type == rhs.type && lhs.frequency == rhs.frequency && lhs.gain == rhs.gain
            && lhs.q == rhs.q && lhs.isEnabled == rhs.isEnabled && lhs.channel == rhs.channel
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(type)
        hasher.combine(frequency)
        hasher.combine(gain)
        hasher.combine(q)
        hasher.combine(isEnabled)
        hasher.combine(channel)
    }
}

struct EQPreset: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var preampDB: Double = 0
    var bands: [EQBand] = []
    /// Where the preset came from, e.g. "AutoEq parametric", "peqdb", "Imported file".
    var source: String?

    // Built-ins carry fixed IDs so device profiles that reference them keep
    // resolving across launches (a fresh UUID() per launch would break them).
    static let flat = EQPreset(id: UUID(uuidString: "6F6C7945-5100-4000-8000-000000000001")!, name: "Flat")

    /// A gentle Harman-style bass+treble curve as a friendly built-in.
    static let builtIns: [EQPreset] = [
        .flat,
        EQPreset(id: UUID(uuidString: "6F6C7945-5100-4000-8000-000000000002")!,
                 name: "Harman Target", preampDB: -4, bands: [
            EQBand(type: .lowShelf, frequency: 105, gain: 4.0, q: 0.71),
            EQBand(type: .peak, frequency: 200, gain: -1.0, q: 1.0),
            EQBand(type: .peak, frequency: 3000, gain: 2.0, q: 1.2),
            EQBand(type: .highShelf, frequency: 10000, gain: 1.5, q: 0.71),
        ], source: "Built-in"),
        EQPreset(id: UUID(uuidString: "6F6C7945-5100-4000-8000-000000000003")!,
                 name: "Late Night", preampDB: -2, bands: [
            EQBand(type: .lowShelf, frequency: 120, gain: -4.0, q: 0.71),
            EQBand(type: .peak, frequency: 2500, gain: 2.0, q: 1.0),
            EQBand(type: .highShelf, frequency: 9000, gain: -2.0, q: 0.71),
        ], source: "Built-in"),
    ]

    var isFlat: Bool { bands.allSatisfy { $0.gain == 0 } && preampDB == 0 }

    /// True when any band filters only the left or only the right channel.
    var isChannelSplit: Bool { bands.contains { $0.channel != .both } }
}

/// Preset + volume remembered per output device.
struct DeviceProfile: Codable, Equatable {
    var deviceUID: String
    var deviceName: String
    var presetID: UUID?
    var presetName: String?
    var autoApply = true
}
