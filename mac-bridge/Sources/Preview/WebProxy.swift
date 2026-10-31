import Vapor
import NIOCore
import NIOHTTP1

/// Reverse-proxies a local web dev server (http://127.0.0.1:<port>/...) so a
/// 127.0.0.1-bound dev server on the Mac is reachable from the iPhone through
/// the bridge (over the Paseo relay). Used by the iOS WKWebView web-preview target.
///
/// v1 is HTTP-only (no WebSocket/HMR upgrade passthrough). HTML responses get a
/// `<base href="<prefix>/">` injected so relative assets resolve back
/// through the proxy.
///
/// `prefix` は中継の入口（プレビューのセッション経由なら `/preview/w/<session>`、Bearer 直なら `/preview/web/<port>`）。
/// `sandboxed` はプレビューのページの sandbox iframe（opaque origin）に出す応答か。そのときだけ
/// CSP sandbox を足し、X-Frame-Options / frame-ancestors を書き換え、CORS を開ける。
enum WebProxy {
    /// 中継した応答に足す CSP。iframe の sandbox 属性と同じ（allow-same-origin は付けない）。
    static let sandboxPolicy = "sandbox allow-scripts allow-forms allow-popups allow-modals allow-downloads"

    static func handle(_ req: Request, port: Int, prefix: String, sandboxed: Bool) async throws -> Response {
        // opaque origin のページの fetch が出す CORS の preflight は上流へ流さず、ここで答える。
        if sandboxed, req.method == .OPTIONS,
           let method = req.headers.first(name: "Access-Control-Request-Method") {
            var headers: HTTPHeaders = [
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Methods": method,
                "Access-Control-Max-Age": "600",
                "Content-Security-Policy": sandboxPolicy,
            ]
            if let h = req.headers.first(name: "Access-Control-Request-Headers") {
                headers.add(name: "Access-Control-Allow-Headers", value: h)
            }
            return Response(status: .noContent, headers: headers)
        }

        // Remainder path after /preview/web/:port/
        let catchall = req.parameters.getCatchall()   // [String] of remaining segments
        let path = catchall.joined(separator: "/")

        // Forward the original query string minus our auth param.
        let forwardedQuery = strippedQuery(req.url.query)
        var uri = "http://127.0.0.1:\(port)/\(path)"
        if let q = forwardedQuery, !q.isEmpty { uri += "?\(q)" }

        // Copy a conservative subset of request headers; drop hop-by-hop + host.
        // Also drop accept-encoding so the upstream replies with identity (no
        // gzip/br). We buffer+rewrite text/html and text/css, and reading a
        // compressed body as a String would corrupt it.
        // Referer / Origin は /preview/ui?s=... など Bridge 側の URL を含みうるので渡さない。
        // Cookie は以前の BuddyOS のプレビュー Cookie（buddyos_pv_*。今は使わないがブラウザに残りうる）だけ
        // 除いて渡す。全部落とすと dev アプリ自身のログイン Cookie まで届かなくなる。
        var headers = HTTPHeaders()
        for (name, value) in req.headers {
            let lower = name.lowercased()
            if lower == "host" || lower == "connection" || lower == "authorization"
                || lower == "content-length" || lower == "accept-encoding"
                || lower == "referer" || lower == "origin" { continue }
            if lower == "cookie" {
                let kept = value.split(separator: ";")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("buddyos_pv_") }
                if !kept.isEmpty { headers.add(name: name, value: kept.joined(separator: "; ")) }
                continue
            }
            headers.add(name: name, value: value)
        }
        // req.client（Vapor 共有の HTTPClient）は既定でリダイレクトを最大 5 回追従し、途中の
        // 302 の Set-Cookie（ログイン POST 直後のセッション Cookie 等）を読み捨ててしまう。
        // 追従しない専用クライアントで 3xx をそのまま iframe に返し、ブラウザに辿らせる。
        let upstream: HTTPClient.Response
        do {
            let request = try HTTPClient.Request(
                url: URI(string: uri).string,
                method: req.method,
                headers: headers,
                body: req.body.data.map { .byteBuffer($0) }
            )
            upstream = try await proxyClient(req.application)
                .execute(request: request, eventLoop: .delegate(on: req.eventLoop), logger: req.logger)
                .get()
        } catch {
            return Response(
                status: .badGateway,
                headers: ["Content-Type": "text/plain; charset=utf-8"],
                body: .init(string: "web preview: cannot reach 127.0.0.1:\(port) (\(error))")
            )
        }

        let response = Response(status: upstream.status)
        // Copy content-type + cache headers; strip hop-by-hop.
        // replaceOrAdd だと Set-Cookie / Link / Vary など複数行のヘッダが最後の
        // 1 本に潰れるので add で重複をそのまま保つ。
        // sandbox の iframe に出すときは、X-Frame-Options: DENY や CSP frame-ancestors 'none' で
        // 真っ白にならないよう SAMEORIGIN / 'self' に書き換える（CSP の他の指定は残す）。
        // 書き換えるのは下で CSP sandbox を足すときだけ（sandbox 無しで枠の制限だけ外さない）。
        // CORS は opaque origin から読めるよう * にそろえる（上流の値は捨てる）。
        // リダイレクトは追従せず返すので、Location もプロキシ経由の URL に直す。
        for (name, value) in upstream.headers {
            let lower = name.lowercased()
            if lower == "transfer-encoding" || lower == "connection" || lower == "content-length" { continue }
            if sandboxed, lower == "access-control-allow-origin" || lower == "access-control-allow-credentials" { continue }
            if sandboxed, lower == "x-frame-options" {
                response.headers.add(name: name, value: "SAMEORIGIN")
            } else if sandboxed, lower == "content-security-policy" {
                response.headers.add(name: name, value: rewriteFrameAncestors(value))
            } else if lower == "location" {
                response.headers.add(name: name, value: rewriteLocation(value, port: port, prefix: prefix, origin: proxyOrigin(req)))
            } else {
                response.headers.add(name: name, value: value)
            }
        }
        if sandboxed {
            // トップレベルで直接開かれても opaque origin のまま（親や Bridge の他のパスを読めない）。
            response.headers.add(name: "Content-Security-Policy", value: sandboxPolicy)
            response.headers.replaceOrAdd(name: "Access-Control-Allow-Origin", value: "*")
        }
        // プロキシしたページから辿るサブリソース・遷移の Referer に、iframe の文書 URL を載せない。
        response.headers.replaceOrAdd(name: "Referrer-Policy", value: "no-referrer")

        let contentType = upstream.headers.first(name: .contentType) ?? ""
        let lowerCT = contentType.lowercased()
        if lowerCT.contains("text/html"), var buf = upstream.body {
            let original = buf.readString(length: buf.readableBytes) ?? ""
            let rewritten = rewriteHTML(original, prefix: prefix)
            response.body = .init(string: rewritten)
            response.headers.replaceOrAdd(name: .contentType, value: contentType)
            response.headers.remove(name: .contentLength)
            response.headers.remove(name: "Content-Encoding")
        } else if lowerCT.contains("text/css"), var buf = upstream.body {
            let original = buf.readString(length: buf.readableBytes) ?? ""
            let rewritten = rewriteCSSURLs(original, prefix: prefix)
            response.body = .init(string: rewritten)
            response.headers.replaceOrAdd(name: .contentType, value: contentType)
            response.headers.remove(name: .contentLength)
            response.headers.remove(name: "Content-Encoding")
        } else if var buf = upstream.body {
            response.body = .init(buffer: buf.readSlice(length: buf.readableBytes) ?? ByteBuffer())
        } else {
            response.body = .empty
        }
        return response
    }

    private struct ProxyClientKey: StorageKey, LockKey {
        typealias Value = HTTPClient
    }

    /// プロキシ専用の HTTPClient（リダイレクトは追従しない）。Application ごとに 1 つ作って
    /// storage に置き、Vapor の共有クライアントと同じく app の shutdown で閉じる。
    private static func proxyClient(_ app: Application) -> HTTPClient {
        app.locks.lock(for: ProxyClientKey.self).withLock {
            if let existing = app.storage[ProxyClientKey.self] { return existing }
            var configuration = app.http.client.configuration
            configuration.redirectConfiguration = .disallow
            let client = HTTPClient(
                eventLoopGroupProvider: .shared(app.eventLoopGroup),
                configuration: configuration,
                backgroundActivityLogger: app.logger
            )
            app.storage.set(ProxyClientKey.self, to: client, onShutdown: { try $0.syncShutdown() })
            return client
        }
    }

    /// 上流の `Location` を iframe から辿れる URL に直す。ルート絶対パス（`/login`）と、同じポートの
    /// `http://127.0.0.1:<port>/...`・`http://localhost:<port>/...` を `<prefix>/...` に置き換える
    /// （そのままだと Bridge のルートへ飛んで壊れる）。相対 URL（リクエスト URL 基準で解決される）は
    /// 触らない。外部 URL は、クエリに入った同じポートへの戻り先（`?redirect_url=http://127.0.0.1:<port>/...`）だけを直す（`origin` があるとき）。
    /// Clerk などのログインは、dev サーバーが自分の見ている `127.0.0.1:<port>` を戻り先にして外部へ飛ばすので、
    /// そのままだと外部から戻るときに端末自身の 127.0.0.1 へ行って「接続が拒否されました」になる。
    static func rewriteLocation(_ location: String, port: Int, prefix: String, origin: String? = nil) -> String {
        if location.hasPrefix("/") {
            // プロトコル相対（`//host/...`）と書き換え済みの値はそのまま。
            if location.hasPrefix("//") || location.hasPrefix(prefix + "/") || location == prefix { return location }
            return prefix + location
        }
        if let local = proxiedPath(location, port: port, prefix: prefix) { return local }
        guard let origin, var comps = URLComponents(string: location),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let items = comps.percentEncodedQueryItems
        else { return location }
        var changed = false
        let rewritten = items.map { item -> URLQueryItem in
            guard let value = item.value?.removingPercentEncoding,
                  let local = proxiedPath(value, port: port, prefix: prefix)
            else { return item }
            changed = true
            return URLQueryItem(name: item.name, value: (origin + local).addingPercentEncoding(withAllowedCharacters: queryValueAllowed))
        }
        guard changed else { return location }
        comps.percentEncodedQueryItems = rewritten
        return comps.string ?? location
    }

    /// 同じポートの `http://127.0.0.1:<port>/...`・`http://localhost:<port>/...` を `<prefix>/...` にする。
    /// そうでなければ nil（プレビューの入口は 1 つのポートにしか通じない）。
    private static func proxiedPath(_ url: String, port: Int, prefix: String) -> String? {
        guard let comps = URLComponents(string: url),
              comps.scheme?.lowercased() == "http",
              let host = comps.host?.lowercased(),
              ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host),
              (comps.port ?? 80) == port
        else { return nil }
        let path = comps.percentEncodedPath
        var out = prefix + (path.hasPrefix("/") ? path : "/" + path)
        if let query = comps.percentEncodedQuery { out += "?" + query }
        if let fragment = comps.percentEncodedFragment { out += "#" + fragment }
        return out
    }

    /// クエリの値として埋め込むときに、そのまま残してよい文字（`&` `=` `?` `/` `:` などは符号化する）。
    private static let queryValueAllowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// 端末から見た Bridge のオリジン（端末内の Paseo プロキシ `http://127.0.0.1:<端末側の番号>`）。
    /// WebView が送ってきた Host をそのまま使う（中継は TCP をそのまま通すので書き換わらない）。
    private static func proxyOrigin(_ req: Request) -> String? {
        guard let host = req.headers.first(name: .host), !host.isEmpty,
              !host.contains("/"), !host.contains("@")
        else { return nil }
        return "http://" + host
    }

    /// Inject `<base href>` right after `<head>` (case-insensitive). If no
    /// `<head>` is present, prepend before `<html>` content as a fallback.
    private static func injectBase(_ html: String, prefix: String) -> String {
        let baseTag = "<base href=\"\(prefix)/\">"
        if let r = html.range(of: "<head>", options: .caseInsensitive) {
            return html.replacingCharacters(in: r, with: "<head>" + baseTag)
        }
        if let r = html.range(of: "<head", options: .caseInsensitive),
           let close = html.range(of: ">", range: r.lowerBound..<html.endIndex) {
            return html.replacingCharacters(in: close, with: ">" + baseTag)
        }
        return baseTag + html
    }

    /// Full HTML rewrite: inject `<base>`, then rewrite root-absolute asset
    /// references the `<base>` tag cannot reach. `<base href>` only affects
    /// *relative* URLs; values that start with `/` (Vite `/@vite/client`,
    /// Next.js `/_next/static/...`, `/assets/app.css`) ignore it entirely and
    /// would resolve against the bridge root — bypassing the proxy and
    /// 404/401-ing, which strips the page's CSS. We rewrite those to the
    /// `<prefix>/` so they route back through this proxy.
    static func rewriteHTML(_ html: String, prefix: String) -> String {
        var s = injectBase(html, prefix: prefix)
        s = rewriteAbsoluteAttrs(s, prefix: prefix)
        s = rewriteCSSURLs(s, prefix: prefix)   // inline <style> url(/...) + @import
        return s
    }

    /// Prefix root-absolute `href`/`src`/`poster`/`action` values with the
    /// proxy path. Skips protocol-relative (`//cdn`) and already-prefixed URLs.
    private static func rewriteAbsoluteAttrs(_ s: String, prefix: String) -> String {
        let pattern = "(\\s(?:href|src|poster|action)\\s*=\\s*[\"'])/(?!/|preview/(?:web|w)/)"
        return s.replacingOccurrences(of: pattern, with: "$1\(template(prefix))/", options: .regularExpression)
    }

    /// Prefix root-absolute `url(/...)` and `@import "/..."` references in CSS
    /// (also applied to inline `<style>` blocks in HTML).
    private static func rewriteCSSURLs(_ s: String, prefix: String) -> String {
        var out = s
        out = out.replacingOccurrences(
            of: "url\\(\\s*([\"']?)/(?!/|preview/(?:web|w)/)",
            with: "url($1\(template(prefix))/",
            options: .regularExpression)
        out = out.replacingOccurrences(
            of: "@import\\s+([\"'])/(?!/|preview/(?:web|w)/)",
            with: "@import $1\(template(prefix))/",
            options: .regularExpression)
        return out
    }

    /// 置換テンプレートに入れる文字列（`$` と `\` を文字として扱わせる）。
    private static func template(_ s: String) -> String {
        NSRegularExpression.escapedTemplate(for: s)
    }

    /// CSP ヘッダ値の `frame-ancestors` ディレクティブだけを `'self'` に置き換える。
    /// 1 行に複数ポリシーが `,` 区切りで入っている場合も各ポリシーごとに処理する。
    private static func rewriteFrameAncestors(_ csp: String) -> String {
        csp.split(separator: ",", omittingEmptySubsequences: false).map { policy in
            policy.split(separator: ";", omittingEmptySubsequences: false).map { directive -> String in
                let name = directive.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .first.map { $0.lowercased() } ?? ""
                guard name == "frame-ancestors" else { return String(directive) }
                let leading = directive.prefix(while: { $0 == " " || $0 == "\t" })
                return String(leading) + "frame-ancestors 'self'"
            }.joined(separator: ";")
        }.joined(separator: ",")
    }

    /// Drop the `apiKey` param from a query string before forwarding upstream.
    private static func strippedQuery(_ query: String?) -> String? {
        guard let query, !query.isEmpty else { return query }
        let kept = query.split(separator: "&").filter { pair in
            let key = pair.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
            return key != "apiKey"
        }
        return kept.joined(separator: "&")
    }
}
