import Foundation
import Vapor

/// ブラウザ（プレビュー中のページ・別のサイト）から Bridge の API に届かないようにする関門。
/// 約束は Windows の originGuard.ts・desktop と同じ。
///
/// - Host: 名前が 127.0.0.1 / localhost / [::1] のどれか（DNS rebinding で別の名前から来た要求を断る）。全ルートで見る。
///   番号は見ない。Paseo の中継から来る要求は、iPhone 側の 127.0.0.1:<端末の中の番号> を Host に載せて届くため。
/// - Origin: 付いていなければ通す（iOS / Android / CLI の hook はブラウザではないので付けない）。付いているなら
///   desktop の画面だけが付ける "buddyos-desktop://app" と完全に一致するときだけ通す。
///   "null"（sandbox の iframe）・http://localhost:* ・http://127.0.0.1:* ・file:// などは全部断る。
///   プレビューのセッションで認証するルート（中継したページから Origin: null で届く）だけはこの判定の外。
///
/// 認証（Bearer の apiKey）が本来の確認で、これは CSRF・DNS rebinding・プレビューを切り離すための追加の層。
enum BridgeRequestGuard {
    static let desktopOrigin = "buddyos-desktop://app"

    private static let loopbackHostnames: Set<String> = ["127.0.0.1", "localhost", "[::1]"]

    /// Host ヘッダ（全部の行）が 1 本だけで、名前が 127.0.0.1 / localhost / [::1] か。番号は任意。
    static func allowedHost(_ values: [String]) -> Bool {
        guard values.count == 1 else { return false }
        let host = values[0].trimmingCharacters(in: .whitespaces).lowercased()
        guard !host.isEmpty else { return false }
        let name: Substring
        let port: Substring?
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return false }
            name = host[...close]
            let rest = host[host.index(after: close)...]
            if rest.isEmpty {
                port = nil
            } else {
                guard rest.hasPrefix(":") else { return false }
                port = rest.dropFirst()
            }
        } else {
            let parts = host.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return false }
            name = parts[0]
            port = parts.count == 2 ? parts[1] : nil
        }
        if let port {
            guard !port.isEmpty, port.count <= 5, port.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let n = Int(port), n <= 65535 else { return false }
        }
        return loopbackHostnames.contains(String(name))
    }

    /// Origin ヘッダ（全部の行）が無いか、ちょうど 1 本で desktop の画面の Origin と完全に一致するか。
    static func allowedOrigin(_ values: [String]) -> Bool {
        if values.isEmpty { return true }
        return values.count == 1 && values[0] == desktopOrigin
    }

    /// プレビューのセッションで認証するルートか（Origin の判定をかけない）。
    /// パスを `/` で分け（空の要素は捨てる）、各要素の %エンコードを戻してから見る（ルーターの照合と同じ見方）。
    ///   /preview/ui, /preview/sim/{stream,tap,swipe}, /preview/w/<session>[/**]
    static func isPreviewSessionPath(_ path: String) -> Bool {
        let parts = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let comps = parts.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        guard comps.first == "preview", comps.count >= 2 else { return false }
        switch comps[1] {
        case "ui":
            return comps.count == 2
        case "sim":
            return comps.count == 3 && ["stream", "tap", "swipe"].contains(comps[2])
        case "w":
            return comps.count >= 3
        default:
            return false
        }
    }

    static func passesHost(_ req: Request) -> Bool {
        allowedHost(req.headers[.host])
    }

    /// Host と Origin の両方を満たすか（プレビューのセッション用ルート以外の HTTP と、すべての WebSocket の upgrade で見る）。
    static func passes(_ req: Request) -> Bool {
        passesHost(req) && allowedOrigin(req.headers[.origin])
    }

    /// 断る理由（通すなら nil）。
    static func rejection(for req: Request) -> String? {
        if !passesHost(req) { return "forbidden_host" }
        if isPreviewSessionPath(req.url.path) { return nil }
        if !allowedOrigin(req.headers[.origin]) { return "forbidden_origin" }
        return nil
    }

    static func forbidden(_ error: String) -> Response {
        Response(
            status: .forbidden,
            headers: ["Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store"],
            body: .init(string: "{\"error\":\"\(error)\"}")
        )
    }

    /// アプリ全体にかける middleware。ルートの本文を読む（collect する）前に走る。
    struct Middleware: AsyncMiddleware {
        func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
            if let error = BridgeRequestGuard.rejection(for: request) {
                // パスは先頭 2 段だけ残す（/preview/w/<session> のセッションをログに残さない）。
                let head = request.url.path.split(separator: "/").prefix(2).joined(separator: "/")
                WebSocketServer.wslog("rejected \(error) \(request.method) /\(head.prefix(48))")
                return BridgeRequestGuard.forbidden(error)
            }
            return try await next.respond(to: request)
        }
    }
}
