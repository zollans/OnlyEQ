import Foundation

/// A searchable entry from an online headphone EQ database.
struct OnlineEntry: Identifiable, Hashable {
    enum Source: String, CaseIterable, Identifiable {
        case peqdb = "peqdb"
        case autoEq = "AutoEq"
        var id: String { rawValue }
    }

    var id: String { "\(source.rawValue)|\(model)|\(reviewer)|\(variant)" }
    var source: Source
    var model: String
    var reviewer: String
    var variant: String

    var subtitle: String { variant.isEmpty || variant == reviewer ? reviewer : "\(reviewer) · \(variant)" }
}

/// peqdb.com client (unofficial JSON API used by their own SPA).
enum PeqdbClient {
    static let listsURL = URL(string: "https://peqdb.com/opt-v3/lists")!
    static let presetURL = URL(string: "https://peqdb.com/opt-v3/preset")!

    static func fetchEntries() async throws -> [OnlineEntry] {
        let (data, _) = try await URLSession.shared.data(from: listsURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let phones = root["phones"] as? [String: [String: [String]]] else {
            throw URLError(.cannotParseResponse)
        }
        var entries: [OnlineEntry] = []
        for (model, reviewers) in phones {
            for (reviewer, variants) in reviewers {
                for variant in (variants.isEmpty ? [""] : variants) {
                    entries.append(OnlineEntry(source: .peqdb, model: model, reviewer: reviewer, variant: variant))
                }
            }
        }
        return entries.sorted { $0.model.localizedCaseInsensitiveCompare($1.model) == .orderedAscending }
    }

    static func fetchPreset(for entry: OnlineEntry) async throws -> EQPreset {
        var request = URLRequest(url: presetURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "phone": [entry.model, entry.reviewer, entry.variant],
            "measurement": NSNull(),
        ])
        let (data, _) = try await URLSession.shared.data(for: request)
        var result = try PresetImporter.importData(data)
        result.preset.name = "\(entry.model) · \(entry.reviewer)"
        result.preset.source = "peqdb"
        return result.preset
    }
}

/// AutoEq (jaakkopasanen/AutoEq) client reading raw files from GitHub.
enum AutoEqClient {
    static let base = "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/"

    struct IndexEntry {
        var name: String
        var path: String  // e.g. "oratory1990/over-ear/Sennheiser HD 650"
    }

    static func fetchEntries() async throws -> [OnlineEntry] {
        let url = URL(string: base + "INDEX.md")!
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotParseResponse) }
        // Lines look like: - [Name](./source/rig/Name) by source
        let regex = try NSRegularExpression(pattern: #"\[([^\]]+)\]\(\./([^)]+)\)"#)
        var entries: [OnlineEntry] = []
        for line in text.components(separatedBy: .newlines) {
            let ns = line as NSString
            guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let name = ns.substring(with: m.range(at: 1))
            let path = ns.substring(with: m.range(at: 2)).removingPercentEncoding ?? ns.substring(with: m.range(at: 2))
            let reviewer = path.components(separatedBy: "/").first ?? "AutoEq"
            entries.append(OnlineEntry(source: .autoEq, model: name, reviewer: reviewer, variant: path))
        }
        return entries
    }

    static func fetchPreset(for entry: OnlineEntry) async throws -> EQPreset {
        // entry.variant carries the repo path; the file is "<Model> ParametricEQ.txt".
        let path = "\(entry.variant)/\(entry.model) ParametricEQ.txt"
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: base + encoded) else {
            throw URLError(.badURL)
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.fileDoesNotExist) }
        var result = try PresetImporter.importData(data)
        result.preset.name = "\(entry.model) · \(entry.reviewer)"
        result.preset.source = "AutoEq"
        return result.preset
    }
}

/// Unified search facade over both databases with in-memory caching.
@MainActor
final class OnlineDatabase: ObservableObject {
    @Published var entries: [OnlineEntry] = []
    @Published var isLoading = false
    @Published var error: String?

    private var cache: [OnlineEntry.Source: [OnlineEntry]] = [:]

    func load(source: OnlineEntry.Source) async {
        error = nil
        if let cached = cache[source] {
            entries = cached
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = switch source {
            case .peqdb: try await PeqdbClient.fetchEntries()
            case .autoEq: try await AutoEqClient.fetchEntries()
            }
            cache[source] = fetched
            entries = fetched
        } catch {
            self.error = "Couldn’t load \(source.rawValue): \(error.localizedDescription)"
            entries = []
        }
    }

    nonisolated static func fetchPreset(for entry: OnlineEntry) async throws -> EQPreset {
        switch entry.source {
        case .peqdb: try await PeqdbClient.fetchPreset(for: entry)
        case .autoEq: try await AutoEqClient.fetchPreset(for: entry)
        }
    }
}
