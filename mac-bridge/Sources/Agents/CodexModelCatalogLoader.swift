import Foundation

enum CodexModelCatalogLoader {
    static func load(executable: String, currentModel: String?) async -> [ProviderCatalog]? {
        // 最長 5 秒の子プロセス待ちなので、協調スレッドの外で待つ。
        guard let data = await ProcessRunner.runAsync(executable, ["debug", "models"], timeout: 5.0)
                .flatMap({ !$0.timedOut && $0.status == 0 ? $0.stdout : nil }),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["models"] as? [[String: Any]] else {
            return nil
        }

        let listed = rows.compactMap { row -> ModelCatalogItem? in
            guard (row["visibility"] as? String) == "list",
                  let slug = nonEmpty(row["slug"] as? String) else {
                return nil
            }
            return ModelCatalogItem(
                id: slug,
                label: nonEmpty(row["display_name"] as? String) ?? slug,
                subtitle: nonEmpty(row["description"] as? String)
            )
        }
        let merged = merge(currentModel: currentModel, models: listed)
        guard !merged.isEmpty else { return nil }
        return [
            ProviderCatalog(
                id: "openai",
                label: "OpenAI",
                models: merged
            )
        ]
    }

    private static func merge(currentModel: String?, models: [ModelCatalogItem]) -> [ModelCatalogItem] {
        var result: [ModelCatalogItem] = []
        var seen = Set<String>()

        func append(_ item: ModelCatalogItem) {
            let id = item.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !seen.contains(id) else { return }
            seen.insert(id)
            result.append(item)
        }

        if let current = nonEmpty(currentModel),
           !models.contains(where: { $0.id == current }) {
            append(ModelCatalogItem(id: current, label: current, subtitle: nil))
        }
        models.forEach(append)
        return result
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
