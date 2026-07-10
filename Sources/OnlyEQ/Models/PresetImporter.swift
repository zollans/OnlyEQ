import Foundation

/// Universal EQ preset parser. Detects the format from content, never from
/// file extension. Supported: AutoEq/Equalizer APO/REW/peqdb/Qudelix parametric
/// text, GraphicEQ lines (Wavelet/AutoEq/JamesDSP), Poweramp JSON, OPRA JSON,
/// eqMac JSON, peqdb API JSON, Peace INI, and OnlyEQ's own JSON.
enum PresetImporter {

    struct ImportResult: Equatable {
        var preset: EQPreset
        /// Human-readable detected format, e.g. "AutoEq parametric".
        var detectedFormat: String
        var warnings: [String] = []
    }

    enum ImportError: LocalizedError, Equatable {
        case unrecognized
        case empty

        var errorDescription: String? {
            switch self {
            case .unrecognized: "Unrecognized EQ format. Supported: AutoEq, Equalizer APO, peqdb, Wavelet/GraphicEQ, Poweramp, OPRA, Peace, REW, eqMac."
            case .empty: "No EQ filters found in the input."
            }
        }
    }

    // MARK: - Entry points

    static func importFile(at url: URL) throws -> ImportResult {
        let data = try Data(contentsOf: url)
        var result = try importData(data)
        if result.preset.name.isEmpty || result.preset.name == "Imported" {
            result.preset.name = url.deletingPathExtension().lastPathComponent
        }
        return result
    }

    static func importData(_ data: Data) throws -> ImportResult {
        if let json = try? JSONSerialization.jsonObject(with: data) {
            return try importJSON(json)
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ImportError.unrecognized
        }
        return try importText(text)
    }

    static func importText(_ raw: String) throws -> ImportResult {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ImportError.empty }

        if let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) {
            return try importJSON(json)
        }
        if text.contains("[Frequencies]") || text.contains("[Gains]") {
            return try parsePeace(text)
        }
        if let graphic = try? parseGraphicEQ(text) {
            return graphic
        }
        return try parseParametricText(text)
    }

    // MARK: - Parametric text (AutoEq / Equalizer APO / REW / peqdb / Qudelix)

    private static let filterLineRegex = try! NSRegularExpression(
        pattern: #"Filter\s*\d+[:\s]\s*(ON|OFF)?\s*([A-Z]+(?:\s+(?:6|12)\s*dB)?)\s+Fc\s+([\d.,]+)\s*k?Hz\s+Gain\s+(-?[\d.,]+)\s*dB(?:\s+(Q|BW\s+Oct)\s+([\d.,]+))?"#,
        options: [.caseInsensitive]
    )
    private static let preampRegex = try! NSRegularExpression(
        pattern: #"Preamp[:\s]\s*(-?[\d.,]+)\s*dB"#, options: [.caseInsensitive]
    )

    static func parseParametricText(_ text: String) throws -> ImportResult {
        var bands: [EQBand] = []
        var warnings: [String] = []
        var preamp: Double = 0
        let isREW = text.contains("Room EQ") || text.contains("Filter Settings file")

        for line in text.components(separatedBy: .newlines) {
            let ns = line as NSString
            if let m = preampRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                preamp = parseNumber(ns.substring(with: m.range(at: 1))) ?? 0
                continue
            }
            guard let m = filterLineRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }

            let onOff = m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)).uppercased() : "ON"
            let typeToken = ns.substring(with: m.range(at: 2)).uppercased()
                .replacingOccurrences(of: " ", with: "")
            var fc = parseNumber(ns.substring(with: m.range(at: 3))) ?? 0
            if line.lowercased().contains("khz") { fc *= 1000 }
            let gain = parseNumber(ns.substring(with: m.range(at: 4))) ?? 0

            var q = 0.707
            if m.range(at: 5).location != NSNotFound, m.range(at: 6).location != NSNotFound {
                let qKind = ns.substring(with: m.range(at: 5)).uppercased()
                let value = parseNumber(ns.substring(with: m.range(at: 6))) ?? 0.707
                if qKind.hasPrefix("BW") {
                    // RBJ: Q = sqrt(2^BW) / (2^BW - 1)
                    let bw = pow(2.0, value)
                    q = sqrt(bw) / (bw - 1)
                } else {
                    q = value
                }
            }

            guard let type = filterType(fromToken: typeToken) else {
                if typeToken == "AP" { warnings.append("Skipped unsupported all-pass filter.") }
                else { warnings.append("Skipped unknown filter type “\(typeToken)”.") }
                continue
            }
            // Fixed-slope shelves (LS 6dB etc.) have no Q — Butterworth default.
            guard fc > 0 else { continue }
            // Skip zero-gain padding bands (Qudelix exports pad with OFF PK 0 dB).
            if onOff == "OFF" && gain == 0 { continue }
            bands.append(EQBand(type: type, frequency: fc, gain: gain, q: q, isEnabled: onOff != "OFF"))
        }

        guard !bands.isEmpty else { throw ImportError.unrecognized }
        // REW files often carry no preamp; leave 0 and let auto-preamp handle it.
        if isREW && preamp == 0 { warnings.append("REW file has no preamp — auto-preamp will be applied.") }
        let format = isREW ? "REW filter settings" : "AutoEq / Equalizer APO parametric"
        return ImportResult(
            preset: EQPreset(name: "Imported", preampDB: preamp, bands: bands, source: format),
            detectedFormat: format, warnings: warnings
        )
    }

    private static func filterType(fromToken token: String) -> FilterType? {
        switch token {
        case "PK", "PEQ", "MODAL": .peak
        case "LS", "LSC", "LSQ", "LS6DB", "LS12DB": .lowShelf
        case "HS", "HSC", "HSQ", "HS6DB", "HS12DB": .highShelf
        case "LP", "LPQ": .lowPass
        case "HP", "HPQ": .highPass
        case "BP": .bandPass
        case "NO", "NOTCH": .notch
        default: nil
        }
    }

    // MARK: - GraphicEQ (Wavelet / AutoEq GraphicEQ / JamesDSP)

    static func parseGraphicEQ(_ text: String) throws -> ImportResult {
        guard let line = text.components(separatedBy: .newlines).first(where: { $0.contains("GraphicEQ:") }) else {
            throw ImportError.unrecognized
        }
        let payload = line.replacingOccurrences(of: "GraphicEQ:", with: "")
        var points: [(f: Double, g: Double)] = []
        for pair in payload.components(separatedBy: ";") {
            let parts = pair.split(separator: " ").compactMap { parseNumber(String($0)) }
            if parts.count == 2 { points.append((parts[0], parts[1])) }
        }
        guard points.count >= 2 else { throw ImportError.empty }
        points.sort { $0.f < $1.f }

        // Sample the graphic curve at the 31 ISO third-octave centers. The Q
        // matching that spacing — sqrt(2^(1/3)) / (2^(1/3) − 1) ≈ 4.318 — keeps
        // adjacent-band overlap from distorting the sampled gains.
        let centers: [Double] = [20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200,
                                 250, 315, 400, 500, 630, 800, 1000, 1250, 1600, 2000,
                                 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000]
        func interpolate(_ f: Double) -> Double {
            if f <= points[0].f { return points[0].g }
            if f >= points[points.count - 1].f { return points[points.count - 1].g }
            for i in 1..<points.count where points[i].f >= f {
                let (f0, g0) = points[i - 1], (f1, g1) = points[i]
                let t = (log10(f) - log10(f0)) / (log10(f1) - log10(f0))
                return g0 + t * (g1 - g0)
            }
            return 0
        }
        let bands = centers.map { EQBand(type: .peak, frequency: $0, gain: (interpolate($0) * 10).rounded() / 10, q: 4.318) }
        // Graphic exports usually bake preamp in (max gain ≤ 0); if not, compensate.
        let maxGain = bands.map(\.gain).max() ?? 0
        let preamp = maxGain > 0 ? -maxGain : 0
        return ImportResult(
            preset: EQPreset(name: "Imported", preampDB: preamp, bands: bands, source: "GraphicEQ"),
            detectedFormat: "GraphicEQ (Wavelet)",
            warnings: ["Graphic curve was fitted onto 31 parametric bands."]
        )
    }

    // MARK: - JSON formats

    static func importJSON(_ json: Any) throws -> ImportResult {
        // Poweramp: top-level array of presets.
        if let array = json as? [[String: Any]], let first = array.first, first["bands"] != nil {
            return try parsePoweramp(first)
        }
        guard let dict = json as? [String: Any] else { throw ImportError.unrecognized }

        // OnlyEQ native preset.
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let preset = try? JSONDecoder().decode(EQPreset.self, from: data),
           !preset.bands.isEmpty {
            return ImportResult(preset: preset, detectedFormat: "OnlyEQ preset")
        }
        // OPRA: {"type": "parametric_eq", "parameters": {"gain_db":…, "bands": […]}}
        if let params = dict["parameters"] as? [String: Any], let bands = params["bands"] as? [[String: Any]] {
            return try parseOPRA(dict, params: params, rawBands: bands)
        }
        // peqdb API: {"filters": [{"type":"PK","f0":…,"gain":…,"Q":…}], "gain": …, "apo": {…}}
        if let filters = dict["filters"] as? [[String: Any]], filters.first?["f0"] != nil {
            return try parsePeqdb(dict, filters: filters)
        }
        // eqMac: {"gains": {"global": -6.4, "bands": [10 gains]}}
        if let gains = dict["gains"] as? [String: Any], let bandGains = gains["bands"] as? [Double] {
            return parseEqMac(dict, global: (gains["global"] as? Double) ?? 0, bandGains: bandGains)
        }
        // Poweramp single object.
        if dict["bands"] != nil, dict["parametric"] != nil {
            return try parsePoweramp(dict)
        }
        throw ImportError.unrecognized
    }

    private static func parseOPRA(_ dict: [String: Any], params: [String: Any], rawBands: [[String: Any]]) throws -> ImportResult {
        let typeMap: [String: FilterType] = [
            "peak_dip": .peak, "low_shelf": .lowShelf, "high_shelf": .highShelf,
            "low_pass": .lowPass, "high_pass": .highPass, "band_pass": .bandPass, "band_stop": .notch,
        ]
        var warnings: [String] = []
        let bands: [EQBand] = rawBands.compactMap { b in
            guard let f = anyDouble(b["frequency"]), let type = typeMap[(b["type"] as? String) ?? "peak_dip"] else {
                warnings.append("Skipped band with unknown type “\((b["type"] as? String) ?? "?")”.")
                return nil
            }
            return EQBand(type: type, frequency: f, gain: anyDouble(b["gain_db"]) ?? 0, q: anyDouble(b["q"]) ?? 0.707)
        }
        guard !bands.isEmpty else { throw ImportError.empty }
        var name = "Imported"
        if let author = dict["author"] as? String { name = "OPRA · \(author)" }
        return ImportResult(
            preset: EQPreset(name: name, preampDB: anyDouble(params["gain_db"]) ?? 0, bands: bands, source: "OPRA"),
            detectedFormat: "OPRA JSON", warnings: warnings
        )
    }

    private static func parsePeqdb(_ dict: [String: Any], filters: [[String: Any]]) throws -> ImportResult {
        let bands: [EQBand] = filters.compactMap { f in
            guard let fc = anyDouble(f["f0"]),
                  let type = filterType(fromToken: ((f["type"] as? String) ?? "PK").uppercased()) else { return nil }
            return EQBand(type: type, frequency: fc, gain: anyDouble(f["gain"]) ?? 0, q: anyDouble(f["Q"]) ?? anyDouble(f["q"]) ?? 0.707)
        }
        guard !bands.isEmpty else { throw ImportError.empty }
        // Prefer the preamp from the bundled APO text (highest band count wins);
        // else negate the max-excursion "gain".
        var preamp = 0.0
        if let apo = dict["apo"] as? [String: String],
           let best = apo.keys.compactMap({ Int($0) }).max(),
           let text = apo[String(best)],
           let parsed = try? parseParametricText(text) {
            preamp = parsed.preset.preampDB
        } else if let gain = anyDouble(dict["gain"]), gain > 0 {
            preamp = -gain
        }
        return ImportResult(
            preset: EQPreset(name: "peqdb preset", preampDB: preamp, bands: bands, source: "peqdb"),
            detectedFormat: "peqdb"
        )
    }

    private static func parseEqMac(_ dict: [String: Any], global: Double, bandGains: [Double]) -> ImportResult {
        let centers: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        let bands = zip(centers, bandGains).map { EQBand(type: .peak, frequency: $0, gain: $1, q: 1.41) }
        let name = (dict["name"] as? String) ?? "eqMac preset"
        return ImportResult(
            preset: EQPreset(name: name, preampDB: global, bands: bands, source: "eqMac"),
            detectedFormat: "eqMac JSON"
        )
    }

    private static func parsePoweramp(_ dict: [String: Any]) throws -> ImportResult {
        guard let rawBands = dict["bands"] as? [[String: Any]] else { throw ImportError.unrecognized }
        var warnings: [String] = []
        let bands: [EQBand] = rawBands.compactMap { b in
            guard let f = anyDouble(b["frequency"]) else { return nil }
            let gain = anyDouble(b["gain"]) ?? 0
            let q = anyDouble(b["q"]) ?? 0
            let type: FilterType
            switch (b["type"] as? Int) ?? (anyDouble(b["type"]).map(Int.init)) ?? 3 {
            case 0: type = .lowShelf
            case 1: type = .highShelf
            case 2: type = .peak  // graphic band
            case 3: type = .peak
            default:
                warnings.append("Skipped band with unknown Poweramp type.")
                return nil
            }
            // Poweramp exports lead with zero-gain shelf placeholder slots.
            if gain == 0 && q == 0 { return nil }
            return EQBand(type: type, frequency: f, gain: gain, q: q > 0 ? q : 1.41)
        }
        guard !bands.isEmpty else { throw ImportError.empty }
        return ImportResult(
            preset: EQPreset(name: (dict["name"] as? String) ?? "Poweramp preset",
                             preampDB: anyDouble(dict["preamp"]) ?? 0, bands: bands, source: "Poweramp"),
            detectedFormat: "Poweramp JSON", warnings: warnings
        )
    }

    // MARK: - Peace INI

    static func parsePeace(_ text: String) throws -> ImportResult {
        var sections: [String: [String: String]] = [:]
        var current = ""
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast())
                sections[current] = sections[current] ?? [:]
            } else if let eq = line.firstIndex(of: "="), !current.isEmpty {
                sections[current]?[String(line[..<eq])] = String(line[line.index(after: eq)...])
            }
        }
        guard let freqs = sections["Frequencies"], !freqs.isEmpty else { throw ImportError.unrecognized }
        let gains = sections["Gains"] ?? [:]
        let qualities = sections["Qualities"] ?? [:]
        let filterTypes = sections["Filters"] ?? [:]
        // Peace filter-type dropdown order (best effort): 1 Peak, 2 Low Shelf,
        // 3 High Shelf, 4 Low Pass, 5 High Pass, 6 Band Pass, 7 Notch.
        let peaceTypes: [Int: FilterType] = [1: .peak, 2: .lowShelf, 3: .highShelf, 4: .lowPass, 5: .highPass, 6: .bandPass, 7: .notch]

        var bands: [EQBand] = []
        var index = 1
        while let fStr = freqs["Frequency\(index)"] {
            let f = parseNumber(fStr) ?? 0
            let g = parseNumber(gains["Gain\(index)"] ?? "0") ?? 0
            let q = parseNumber(qualities["Quality\(index)"] ?? "1.41") ?? 1.41
            var type = FilterType.peak
            if let tStr = filterTypes["Filter\(index)"], let t = Int(tStr), let mapped = peaceTypes[t] {
                type = mapped
            }
            if f > 0 { bands.append(EQBand(type: type, frequency: f, gain: g, q: q)) }
            index += 1
        }
        guard !bands.isEmpty else { throw ImportError.empty }
        return ImportResult(
            preset: EQPreset(name: "Peace preset", preampDB: 0, bands: bands, source: "Peace"),
            detectedFormat: "Peace (Equalizer APO)",
            warnings: ["Peace filter types are mapped best-effort; verify shelf bands."]
        )
    }

    // MARK: - Helpers

    private static func parseNumber(_ s: String) -> Double? {
        Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    private static func anyDouble(_ v: Any?) -> Double? {
        switch v {
        case let d as Double: d
        case let i as Int: Double(i)
        case let n as NSNumber: n.doubleValue
        case let s as String: parseNumber(s)
        default: nil
        }
    }
}
