import Foundation

final class CodexConfigStore {
    private let fileManager = FileManager.default

    func currentModel() -> String? {
        stringValue(for: "model")
    }

    /// model が nil なら config.toml の現在の model 基準。
    func supportedReasoningEfforts(model: String? = nil) -> [String] {
        let cacheURL = configURL().deletingLastPathComponent().appendingPathComponent("models_cache.json")
        guard let data = try? Data(contentsOf: cacheURL) else {
            return ["low", "medium", "high", "xhigh"]
        }
        return CodexReasoningOptions.parse(data, model: model ?? currentModel())
    }

    func currentReasoningEffort() -> String? {
        stringValue(for: "model_reasoning_effort")
    }

    func currentApprovalPolicy() -> String? {
        stringValue(for: "approval_policy")
    }

    func currentSandboxMode() -> String? {
        stringValue(for: "sandbox_mode")
    }

    func currentCodexMode(approvalPolicy: String? = nil, sandboxMode: String? = nil) -> String? {
        let approval = approvalPolicy ?? currentApprovalPolicy()
        let sandbox = sandboxMode ?? currentSandboxMode()
        switch (sandbox, approval) {
        case ("read-only", _):
            return "plan"
        // 承認を尋ねない workspace-write が auto、尋ねる（on-request など。未設定も Codex の既定は尋ねる）のが ask。
        case ("workspace-write", "never"):
            return "auto"
        case ("workspace-write", _):
            return "ask"
        case ("danger-full-access", _):
            return "dangerous"
        default:
            return nil
        }
    }

    func setModel(_ model: String) throws {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "CodexConfigStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "model is required"]
            )
        }

        try writeTopLevelString(key: "model", value: trimmed)
    }

    /// 書き込まずに検証だけする（setModel が部分適用しないよう、先に全部検証するため）。
    func validatedReasoningEffort(_ effort: String, model: String?) throws -> String {
        let trimmed = effort.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = Set(supportedReasoningEfforts(model: model))
        guard allowed.contains(trimmed) else {
            throw NSError(
                domain: "CodexConfigStore",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "unsupported reasoning effort: \(trimmed)"]
            )
        }
        return trimmed
    }

    func setReasoningEffort(_ effort: String) throws {
        try writeReasoningEffort(validatedReasoningEffort(effort, model: nil))
    }

    /// 検証済みの値を書く。
    func writeReasoningEffort(_ effort: String) throws {
        try writeTopLevelString(key: "model_reasoning_effort", value: effort)
    }

    /// mode を sandbox / approval の組に変換する（書き込みはしない）。
    func codexModeValues(_ mode: String) throws -> (sandbox: String, approval: String) {
        let trimmed = mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch trimmed {
        case "plan":
            return ("read-only", "on-request")
        case "ask":
            // 毎回尋ねる（mainagent の子の上限が「毎回尋ねる」のときにも使う）。
            return ("workspace-write", "on-request")
        case "auto":
            return ("workspace-write", "never")
        case "dangerous":
            return ("danger-full-access", "never")
        default:
            throw NSError(
                domain: "CodexConfigStore",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "unsupported codex mode: \(trimmed)"]
            )
        }
    }

    func setCodexMode(_ mode: String) throws {
        try applyCodexMode(codexModeValues(mode))
    }

    func applyCodexMode(_ values: (sandbox: String, approval: String)) throws {
        try writeTopLevelString(key: "sandbox_mode", value: values.sandbox)
        try writeTopLevelString(key: "approval_policy", value: values.approval)
    }

    func loadBuddyModelCatalog() -> [ProviderCatalog]? {
        let url = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".buddyos", isDirectory: true)
            .appendingPathComponent("models.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let codex = root["codex"] as? [String: Any],
              let providers = codex["providers"] as? [[String: Any]] else {
            return nil
        }

        let result = providers.compactMap { provider -> ProviderCatalog? in
            guard let id = provider["id"] as? String, !id.isEmpty else { return nil }
            let label = (provider["label"] as? String) ?? id
            let modelRows = (provider["models"] as? [[String: Any]]) ?? []
            let models = modelRows.compactMap { item -> ModelCatalogItem? in
                guard let mid = item["id"] as? String, !mid.isEmpty else { return nil }
                return ModelCatalogItem(
                    id: mid,
                    label: (item["label"] as? String) ?? mid,
                    subtitle: item["subtitle"] as? String
                )
            }
            return ProviderCatalog(id: id, label: label, models: models)
        }
        return result.isEmpty ? nil : result
    }

    func defaultModelIds(recent: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for id in ([currentModel()].compactMap { $0 } + recent + ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.3-codex-spark"]) {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    private func configURL() -> URL {
        if let explicit = nonEmpty(ProcessInfo.processInfo.environment["BUDDYOS_CODEX_HOME"])
            ?? nonEmpty(ProcessInfo.processInfo.environment["CODEX_HOME"]) {
            return URL(fileURLWithPath: explicit, isDirectory: true).appendingPathComponent("config.toml")
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml")
    }

    private func stringValue(for key: String) -> String? {
        guard let raw = try? String(contentsOf: configURL(), encoding: .utf8) else {
            return nil
        }
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        return firstMatch(
            in: raw,
            pattern: #"(?m)^\s*\#(escapedKey)\s*=\s*"((?:\\.|[^"\\])*)""#
        ).map(unescapeTomlBasicString)
    }

    private func writeTopLevelString(key: String, value: String) throws {
        let url = configURL()
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let line = "\(key) = \"\(escapeTomlBasicString(value))\""
        let pattern = #"(?m)^\s*\#(escapedKey)\s*=\s*(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^\n#]+)"#
        let next: String
        if let range = raw.range(of: pattern, options: .regularExpression) {
            next = raw.replacingCharacters(in: range, with: line)
        } else {
            next = raw.isEmpty ? "\(line)\n" : "\(line)\n\(raw)"
        }
        try next.write(to: url, atomically: true, encoding: .utf8)
    }

    private func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private func escapeTomlBasicString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func unescapeTomlBasicString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
