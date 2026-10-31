import Foundation

/// Read the vendor's model-specific capabilities, shared by display and validation.
enum CodexReasoningOptions {
    static func parse(_ data: Data, model: String?) -> [String] {
        let fallback = ["low", "medium", "high", "xhigh"]
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]],
              let row = models.first(where: { $0["slug"] as? String == model }),
              let levels = row["supported_reasoning_levels"] as? [[String: Any]] else { return fallback }
        var seen = Set<String>()
        return levels.compactMap { $0["effort"] as? String }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
