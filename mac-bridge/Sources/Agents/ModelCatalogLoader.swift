import Foundation

/// hermes (Python) の `list_authenticated_providers` を呼び出して、
/// ユーザーが認証済みのプロバイダとそのモデル一覧を取得する。
/// プロバイダ/モデル定義は hermes 側 (`hermes login`, `hermes auth add` の結果)
/// を唯一の正とし、Bridge は中継だけ行う。
enum ModelCatalogLoader {
    /// 最長 30 秒かかるので、協調スレッドの外で待つ（async の文脈から同期で呼ぶとスレッドをふさぐ）。
    static func load(agentId: String) async -> [ProviderCatalog] {
        guard agentId == "hermes" else { return [] }
        return await ProcessRunner.offload { loadFromHermes() }
    }

    private static func loadFromHermes() -> [ProviderCatalog] {
        guard let python = locateHermesPython(),
              FileManager.default.isExecutableFile(atPath: python) else {
            log("hermes_cli を持つ python が見つからない")
            return []
        }

        let script = """
        import json, sys
        try:
            from hermes_cli.model_switch import list_authenticated_providers
            # max_models 既定 8 だと CLI 表示と乖離する (Copilot 16, Z.AI 13 等)。
            # 上限を実質外して curated 全件を取る。
            providers = list_authenticated_providers(max_models=1000)
            out = []
            for p in providers:
                models = p.get('models') or []
                out.append({
                    'slug': p.get('slug', ''),
                    'name': p.get('name', p.get('slug', '')),
                    'models': [str(m) for m in models if m],
                })
            sys.stdout.write(json.dumps(out, ensure_ascii=False))
        except Exception as exc:
            sys.stderr.write(f'list_authenticated_providers failed: {exc}\\n')
            sys.stdout.write('[]')
        """

        // ~/.local/bin/hermes ラッパと同じく PYTHONPATH / PYTHONHOME を外して起動する。
        var env = ChildEnvironment.base()
        env.removeValue(forKey: "PYTHONPATH")
        env.removeValue(forKey: "PYTHONHOME")
        // live fetch は provider ごとに最大 5 秒かかる (実測 5 provider で約 9 秒)。
        // waitUntilExit 後に読むと出力 64KB 超でデッドロックするので ProcessRunner で並行ドレインする。
        guard let r = ProcessRunner.run(python, ["-c", script], timeout: 30, environment: env) else {
            log("起動失敗: \(python)")
            return []
        }
        let arr: [[String: Any]]? = r.timedOut
            ? nil
            : (try? JSONSerialization.jsonObject(with: r.stdout)) as? [[String: Any]]
        guard let arr, !arr.isEmpty else {
            // import 失敗等は Python 側で '[]' に握りつぶされるので、原因は stderr に出す。
            let stderr = String(decoding: r.stderr.suffix(2000), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            log("一覧が空 (python=\(python) status=\(r.status) timedOut=\(r.timedOut)) \(stderr)")
            return []
        }
        return arr.compactMap { dict -> ProviderCatalog? in
            guard let slug = dict["slug"] as? String, !slug.isEmpty else { return nil }
            let name = (dict["name"] as? String) ?? slug
            let modelIds = (dict["models"] as? [String]) ?? []
            let models = modelIds.map { ModelCatalogItem(id: $0, label: $0, subtitle: nil) }
            return ProviderCatalog(id: slug, label: name, models: models)
        }
    }

    /// hermes_cli を import できる venv の python を返す。見つからなければ nil。
    /// 直接 venv python を叩いた方が起動が速い (ラッパを経由しなくて済む)。
    /// 汎用の python3 (Homebrew 等) は hermes_cli を持たず、import 失敗が '[]' に化けて
    /// 「モデル 0 件」になるので候補に入れない。
    /// venv の bin/python は Homebrew python への symlink だが、realpath に解決すると
    /// pyvenv.cfg が効かず venv 外として起動されるため、パスは解決せずそのまま使う。
    private static func locateHermesPython() -> String? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["HERMES_PYTHON"] {
            return override
        }
        // HermesAdapter.locateExecutable は HERMES_BIN を最優先するので、チャットと同じ hermes の
        // python を使うためにここでも固定候補より先に見る。
        if let override = ProcessInfo.processInfo.environment["HERMES_BIN"],
           let python = pythonFromLauncher(override) {
            return python
        }
        let candidates = [
            // 公式 install.sh (git 版) の配置
            "\(NSHomeDirectory())/.hermes/hermes-agent/venv/bin/python",
            "\(NSHomeDirectory())/develop/hermes-agent/venv/bin/python3",
            "\(NSHomeDirectory())/.local/share/uv/tools/hermes-agent/bin/python3",
        ]
        if let found = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) {
            return found
        }
        // fallback: HermesAdapter.locateExecutable と同じ順で既定の hermes 本体を探し、そこから python を抜く
        let hermesBin = [
            "/opt/homebrew/bin/hermes",
            "/usr/local/bin/hermes",
            "\(NSHomeDirectory())/.local/bin/hermes",
        ].first(where: { fm.isExecutableFile(atPath: $0) })
        guard let bin = hermesBin else { return nil }
        return pythonFromLauncher(bin)
    }

    /// hermes の起動スクリプトから python のパスを取り出す。
    /// - pip/uv の entry point: `#!/path/to/venv/bin/python3` の shebang
    /// - install.sh の bash ラッパ: `exec "/path/to/venv/bin/python" ".../hermes" "$@"`
    /// - パスが長い場合の sh ポリグロット: `'''exec' "/path/to/python" "$0" "$@"`
    /// `#!/usr/bin/env python3` 形式は汎用 python になるので採用しない。
    private static func pythonFromLauncher(_ bin: String) -> String? {
        let fm = FileManager.default
        guard let raw = try? String(contentsOfFile: bin, encoding: .utf8) else { return nil }
        let isPython: (String) -> Bool = { path in
            (path as NSString).lastPathComponent.hasPrefix("python") && fm.isExecutableFile(atPath: path)
        }
        let lines = raw.split(separator: "\n").prefix(20)
        if let first = lines.first, first.hasPrefix("#!"),
           let interp = first.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "\t" }).first,
           interp != "/usr/bin/env", isPython(String(interp)) {
            return String(interp)
        }
        for line in lines {
            guard let execRange = line.range(of: "exec") else { continue }
            let rest = line[execRange.upperBound...]
            guard let open = rest.firstIndex(of: "\"") else { continue }
            let afterOpen = rest[rest.index(after: open)...]
            guard let close = afterOpen.firstIndex(of: "\"") else { continue }
            let path = String(afterOpen[..<close])
            if isPython(path) { return path }
        }
        return nil
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[hermes.models] \(message)\n".utf8))
    }
}
