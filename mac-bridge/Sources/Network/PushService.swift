import Foundation
import Crypto
import APNS
import APNSCore
import Logging

/// APNs (Apple Push Notification service) 送信ラッパ。
///
/// 宛先は DeviceStore の各端末の `push`（spec/PROTOCOL-v3.md §14.1）。**平文の本文は送らない。**
/// 端末ごとに k_push で封をした `e2e` だけを送り、APNs に見せる文言は決まった仮の文言（ja / en。§14.2）。
/// iOS の NSE が `kid` と `bid` で Bridge の公開鍵を引いて復号し、表示を差し替える（§14.3）。
///
/// 送り方（`BridgeConfig.pushMode`、`BUDDYOS_PUSH_MODE`）:
///   - none        : 送らない（公開版の既定）。
///   - convex      : 登録簿の `/v3/push` へ 1 件ずつ POST する（端末トークン `bdt_` で認証。§15.6）。
///                   宛先の一覧は `/v3/push-targets` で登録する（Bridge が登録した宛先にしか送れない）。
///                   `BUDDYOS_PUSH_RELAY_URL` + `BUDDYOS_PUSH_RELAY_TOKEN` があれば、その中継へ同じ本文で送る。
///   - apns-direct : `.p8` の JWT で `api.push.apple.com` へ直送（開発者自身の Mac での自己利用）。
///   - auto        : `.p8` があれば apns-direct、無ければ convex。
///
/// apns-direct の設定（起動時の環境変数。無ければ OfficialDefaults の値）:
///   APNS_KEY_PATH   = ~/.buddyos/AuthKey_<KEY_ID>.p8
///   APNS_KEY_ID     = 10 桁の英数字
///   APNS_TEAM_ID    = 10 桁の英数字
///   APNS_BUNDLE_ID  = iOS アプリの bundle id
///   APNS_ENV        = development | production (default: development)
actor PushService {
    static let shared = PushService()

    private enum Mode { case direct, relay, off }
    private var mode: Mode = .direct

    private var client: APNSClient<JSONDecoder, JSONEncoder>?
    // client を作り直すたびに進める世代番号と、進行中の再構成。actor 再入で複数の送信が
    // 同時に接続エラーになっても、再構成を 1 本にまとめるために使う (reconfigure 参照)。
    private var clientGeneration = 0
    private var reconfigureTask: Task<Void, Never>?
    private var bundleId: String = ""
    private var configured = false
    private var configurationError: String?

    // relay モード設定
    private var relayURL: URL?
    private var relayToken: String?
    /// 既定の中継（Convex の /v3/push）を端末トークンで使うモード。トークンはサインイン後に作られるので送信時に読む。
    private var relayUsesDeviceToken = false

    /// 登録簿（Convex）の site（env → account.config.json → 配布物の既定 → nil）。nil なら登録簿を使わない。
    static func convexSite() -> String? {
        BridgeConfig.current.convexSite().value
    }

    private func currentRelayToken() -> String? {
        relayUsesDeviceToken ? KeyStore.deviceToken() : relayToken
    }
    // direct モードで APNSClient を構成した環境 ("development" | "production")。
    // この環境に一致する token だけ direct で送る（不一致 token は別環境＝送っても
    // BadDeviceToken になり valid token を誤って外してしまうため、送らずスキップ）。
    private var directEnv: String = "development"

    private let devices: DeviceStore
    /// 宛先の登録（/v3/push-targets）を 2 秒まとめるための予約。
    private var targetsSyncTask: Task<Void, Never>?

    init(devices: DeviceStore = .shared) {
        self.devices = devices
    }

    func configure() async {
        guard !configured else { return }
        configured = true

        let env = ProcessInfo.processInfo.environment
        let settings = BridgeConfig.current
        bundleId = settings.apns.bundleId ?? ""
        let pushMode = settings.pushMode.value

        if pushMode == .none {
            mode = .off
            WebSocketServer.wslog("[PushService] off (push mode none; set BUDDYOS_PUSH_MODE to enable)")
            return
        }

        // 中継を指定されていれば（URL + token が揃っていれば）その relay。
        if pushMode != .apnsDirect,
           let urlStr = env["BUDDYOS_PUSH_RELAY_URL"], let url = URL(string: urlStr),
           let token = env["BUDDYOS_PUSH_RELAY_TOKEN"], !token.isEmpty {
            mode = .relay
            relayURL = url
            relayToken = token
            WebSocketServer.wslog("[PushService] ready mode=relay url=\(url.absoluteString)")
            return
        }

        // direct モード（auto と apns-direct）。鍵のファイルがあるときだけ。
        mode = .direct
        let envName = (env["APNS_ENV"] ?? "development").lowercased()
        let environment: APNSEnvironment = (envName == "production") ? .production : .development
        directEnv = (envName == "production") ? "production" : "development"

        guard pushMode != .convex, let keyPath = settings.apns.keyPath,
              FileManager.default.fileExists(atPath: keyPath) else {
            if pushMode == .apnsDirect {
                mode = .off
                WebSocketServer.wslog("[PushService] off (apns-direct needs a readable APNS_KEY_PATH)")
                return
            }
            // 鍵が無い Mac（配布版の一般ユーザー）: 登録簿の中継（/v3/push）を端末トークンで使う。
            // 端末トークンが無い（未サインイン）間は送れない。サインインすると送れるようになる。
            guard let site = Self.convexSite(), let url = URL(string: site + "/v3/push") else {
                mode = .off
                WebSocketServer.wslog("[PushService] off (no registry; set BUDDYOS_CONVEX_SITE to use convex push)")
                return
            }
            mode = .relay
            relayURL = url
            relayUsesDeviceToken = true
            WebSocketServer.wslog("[PushService] ready mode=relay(default convex /v3/push)")
            return
        }
        guard let keyId = settings.apns.keyId, !keyId.isEmpty, let teamId = settings.apns.teamId, !teamId.isEmpty,
              !bundleId.isEmpty else {
            mode = .off
            WebSocketServer.wslog("[PushService] off (apns-direct needs APNS_KEY_ID, APNS_TEAM_ID and APNS_BUNDLE_ID)")
            return
        }

        do {
            let pem = try String(contentsOfFile: keyPath, encoding: .utf8)
            let privateKey = try P256.Signing.PrivateKey(pemRepresentation: pem)
            let config = APNSClientConfiguration(
                authenticationMethod: .jwt(
                    privateKey: privateKey,
                    keyIdentifier: keyId,
                    teamIdentifier: teamId
                ),
                environment: environment
            )
            client = APNSClient(
                configuration: config,
                eventLoopGroupProvider: .createNew,
                responseDecoder: JSONDecoder(),
                requestEncoder: JSONEncoder()
            )
            WebSocketServer.wslog("[PushService] ready mode=direct env=\(envName) bundleId=\(bundleId)")
        } catch {
            configurationError = "APNs init failed: \(error)"
            WebSocketServer.wslog("[PushService] disabled: \(configurationError!)")
        }
    }

    /// 検証用: 登録済みの端末にテスト通知を送る（E2E。平文では送らない）。
    /// registered=0 なら宛先が無い（iOS のエンタイトルメント/許可の問題）。registered>remaining なら一部が無効トークン。
    func sendTest() async -> (registered: Int, remaining: Int, error: String?) {
        let before = devices.pushTargets().count
        if mode == .off { return (before, before, "push is off (BUDDYOS_PUSH_MODE)") }
        if mode == .direct {
            if let configurationError { return (before, before, configurationError) }
            guard client != nil else { return (before, before, "APNs client 未初期化") }
        }
        await broadcast(title: "BuddyOS", body: "テスト通知です 🔔", payload: ["kind": "test"])
        let after = devices.pushTargets().count
        return (before, after, mode == .relay && relayURL == nil ? "relay 未設定" : nil)
    }

    /// 端末 D の WS の `register_push_token`（spec/PROTOCOL-v3.md §14.1）。`content` を小文字にして `^[0-9a-f]{64,200}$` を確かめ、
    /// D の行に入れる。同じトークンが別の端末の行にあり clientDeviceId が違えば、何も変えずに断る。
    @discardableResult
    func registerToken(_ token: String, environment: String = "development", locale: String = "ja",
                       deviceKeyId: String) -> DeviceStore.PushResult? {
        let normalized = token.lowercased()
        guard Self.isValidToken(normalized) else {
            WebSocketServer.wslog("[PushService] reject token len=\(normalized.count)")
            return nil
        }
        let env = (environment.lowercased() == "production") ? "production" : "development"
        let loc = locale.lowercased().hasPrefix("en") ? "en" : "ja"
        let result = devices.setPush(deviceKeyId: deviceKeyId, token: normalized, env: env, locale: loc)
        switch result {
        case .conflict:
            WebSocketServer.wslog("[PushService] token already belongs to another device — refused device=\(deviceKeyId.prefix(8))")
        case .stored:
            WebSocketServer.wslog("[PushService] register token=\(normalized.prefix(8))… env=\(env) device=\(deviceKeyId.prefix(8))")
        case .unchanged, .noDevice:
            break
        }
        return result
    }

    /// `^[0-9a-f]{64,200}$`（小文字にした後）。
    static func isValidToken(_ s: String) -> Bool {
        (64...200).contains(s.utf8.count) && s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    /// `tokenHash = hex(SHA256(小文字の 16 進のトークン文字列の UTF-8))`。
    static func tokenHash(_ token: String) -> String {
        SHA256.hash(data: Data(token.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Convex に渡す env（`development` は `sandbox`）。
    static func convexEnv(_ env: String) -> String { env == "production" ? "production" : "sandbox" }

    /// 平文の title / body の上限（Unicode のスカラー値）。Convex の `/v3/push` は `e2e.c` を base64 で 4096 文字まで
    /// しか受け付けない（平文で約 3 KB）。承認要求の本文はコマンドそのものが入って長くなりうるので、封をする前に切る。
    static let maxTitleScalars = 64
    static let maxBodyScalars = 300

    /// 平文 = {"title","body","payload"}（spec/PROTOCOL-v3.md §14.2）。NSE が復号して表示と userInfo を差し替える。
    static func plaintext(title: String, body: String, payload: [String: String]) -> Data? {
        struct PlainPush: Codable {
            let title: String
            let body: String
            let payload: [String: String]
        }
        func cut(_ s: String, _ n: Int) -> String { String(String.UnicodeScalarView(s.unicodeScalars.prefix(n))) }
        return try? JSONEncoder().encode(PlainPush(title: cut(title, maxTitleScalars), body: cut(body, maxBodyScalars), payload: payload))
    }

    /// 全端末に alert push を送る。`payload` は notification tap 時の deeplink 用 metadata（暗号文の中にだけ入る）。
    func broadcast(title: String, body: String, payload: [String: String]) async {
        guard let plaintext = Self.plaintext(title: title, body: body, payload: payload) else { return }
        await deliver(to: devices.pushTargets()) { _ in plaintext }
    }

    /// スマホで許可する申し込み（spec/PROTOCOL-v3.md §10.4.1）。許可できる端末で push の宛先がある端末にだけ、
    /// E2E の push を 1 回送る。title は申し込んだ端末の表示名、本文は push の locale（ja / en）で選ぶ。
    func sendPairRequest(pendingId: String, requester: String, bridgeName: String) async {
        let targets = devices.approverPushTargets()
        guard !targets.isEmpty else { return }
        let payload = ["kind": "pair_request", "pendingId": pendingId]
        let ja = Self.plaintext(title: requester, body: Self.pairRequestBody(locale: "ja", bridgeName: bridgeName), payload: payload)
        let en = Self.plaintext(title: requester, body: Self.pairRequestBody(locale: "en", bridgeName: bridgeName), payload: payload)
        await deliver(to: targets) { $0.locale == "en" ? en : ja }
        WebSocketServer.wslog("[PushService] pair_request sent to \(targets.count) approver(s)")
    }

    /// pair_request の本文。
    static func pairRequestBody(locale: String, bridgeName: String) -> String {
        locale == "en"
            ? "Trying to connect to this PC (\(bridgeName)). To allow it, enter the 6-digit code shown on that device."
            : "この PC（\(bridgeName)）につなごうとしています。許可するには、その端末に出ている 6 桁を入力してください。"
    }

    /// 宛先ごとに k_push で封をして送る（平文では送らない）。`plaintext` は宛先ごとの平文（nil ならその宛先は飛ばす）。
    private func deliver(to targets: [(deviceKeyId: String, device: DeviceStore.Device, push: DeviceStore.Push)],
                         plaintext: (DeviceStore.Push) -> Data?) async {
        guard mode != .off, !targets.isEmpty else { return }
        guard let priv = KeyStore.e2eKey() else {
            WebSocketServer.wslog("[PushService] e2e-key unavailable — not sending")
            return
        }
        let bridgeId = KeyStore.loadOrCreateBridgeId()
        let kid = KeyStore.e2eKid()
        // direct 送信で接続エラー時に APNs クライアントを作り直すのは 1 回の送信につき 1 度まで。
        var didReconfigure = false
        for target in targets {
            guard let plaintext = plaintext(target.push) else { continue }
            guard let devicePub = TunnelV3.b64uDecodeStrict(target.device.pub, length: 32),
                  let key = try? E2ECrypto.derivePushKey(
                      privateKey: priv, peerPublicKey: devicePub,
                      bridgeId: bridgeId, deviceId: target.device.clientDeviceId
                  ),
                  let sealed = try? E2ECrypto.sealPush(plaintext: plaintext, key: key)
            else {
                // 暗号化できない端末に平文でフォールバックはしない (fail-closed)
                WebSocketServer.wslog("[PushService] e2e seal failed device=\(target.deviceKeyId.prefix(8)) — skipped")
                continue
            }
            let box = E2EBox(v: 1, bid: bridgeId, kid: kid,
                             n: sealed.nonce.base64EncodedString(), c: sealed.ciphertext.base64EncodedString())
            if mode == .relay {
                await sendViaRelay(token: target.push.token, env: target.push.env, locale: target.push.locale, box: box)
            } else {
                await sendDirect(token: target.push.token, env: target.push.env, locale: target.push.locale,
                                 box: box, didReconfigure: &didReconfigure)
            }
        }
    }

    // MARK: - E2E の箱と仮の文言

    /// relay/APNs に見せる仮の文言（spec/PROTOCOL-v3.md §15.6。登録簿と同じ）。実体は NSE が data.e2e を復号して差し替える。
    static func placeholder(locale: String) -> (title: String, body: String) {
        locale == "en" ? ("BuddyOS", "You have a new notification") : ("BuddyOS", "新しい通知があります")
    }

    /// APNs userInfo トップレベルの `e2e` オブジェクト（§14.2）。n/c は標準 base64。
    struct E2EBox: Codable, Equatable {
        let v: Int
        let bid: String
        let kid: String
        let n: String
        let c: String
    }

    /// `/v3/push` の本文（1 回に 1 件の `token`。title / body は送らない）。
    static func relayBody(token: String, env: String, locale: String, box: E2EBox) -> [String: Any] {
        [
            "environment": convexEnv(env),
            "token": token,
            "e2e": ["v": box.v, "bid": box.bid, "kid": box.kid, "n": box.n, "c": box.c],
            "placeholder": locale == "en" ? "en" : "ja",
            "interruptionLevel": "time-sensitive",
        ]
    }

    // MARK: - relay モード（/v3/push）

    private func sendViaRelay(token: String, env: String, locale: String, box: E2EBox, retried: Bool = false) async {
        guard let relayURL, let relayToken = currentRelayToken() else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: Self.relayBody(token: token, env: env, locale: locale, box: box)) else { return }
        var req = URLRequest(url: relayURL, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(relayToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = data
        TrafficMeter.shared.record("push.relay.out", bytes: data.count)
        do {
            let (respData, resp) = try await URLSession.shared.data(for: req)
            TrafficMeter.shared.record("push.relay.in", bytes: respData.count)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let obj = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any]
            if obj?["invalid"] as? Bool == true {
                // APNs が無効と答えた。その端末の宛先を外して登録し直す。
                devices.clearPush(token: token)
                WebSocketServer.wslog("[PushService] relay: invalid token removed token=\(token.prefix(8))…")
            } else if status == 403, obj?["error"] as? String == "unknown_token", !retried {
                // Convex の宛先が古い。登録し直してから 1 回だけ送り直す。
                await syncTargetsNow()
                await sendViaRelay(token: token, env: env, locale: locale, box: box, retried: true)
                return
            }
            WebSocketServer.wslog("[PushService] relay e2e env=\(Self.convexEnv(env)) token=\(token.prefix(8))… status=\(status)")
        } catch {
            WebSocketServer.wslog("[PushService] relay e2e send failed error=\(error)")
        }
    }

    // MARK: - 宛先の登録（/v3/push-targets）

    /// 宛先が変わったら 2 秒まとめてから登録する。
    func scheduleTargetsSync() {
        guard mode == .relay, relayUsesDeviceToken else { return }
        targetsSyncTask?.cancel()
        targetsSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.syncTargetsNow()
        }
    }

    /// `/v3/push-targets` の本文（この Bridge の宛先を丸ごと置き換える。20 件まで）。
    static func targetsBody(_ targets: [DeviceStore.Push]) -> [String: Any] {
        var seen = Set<String>()
        var out: [[String: String]] = []
        for p in targets {
            let hash = tokenHash(p.token)
            guard seen.insert(hash).inserted else { continue }
            out.append(["tokenHash": hash, "env": convexEnv(p.env)])
            if out.count >= 20 { break }
        }
        return ["targets": out]
    }

    /// すぐ登録する（起動後に初めて登録に成功したとき・unknown_token のとき）。
    func syncTargetsNow() async {
        guard mode == .relay, relayUsesDeviceToken, let token = KeyStore.deviceToken(),
              let site = Self.convexSite(), let url = URL(string: site + "/v3/push-targets") else { return }
        let body = Self.targetsBody(devices.pushTargets().map { $0.push })
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = data
        TrafficMeter.shared.record("registry.out", bytes: data.count)
        do {
            let (respData, resp) = try await URLSession.shared.data(for: req)
            TrafficMeter.shared.record("registry.in", bytes: respData.count)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            WebSocketServer.wslog("[PushService] push-targets status=\(status) count=\((body["targets"] as? [Any])?.count ?? 0)")
        } catch {
            WebSocketServer.wslog("[PushService] push-targets failed: \(error)")
        }
    }

    // MARK: - Live Activity（/v3/live-activity-targets・/v3/live-activity）

    /// Live Activity の宛先を登録簿へ丸ごと置き換えて登録する（新しい順に 8 件まで。空なら全部消す）。
    /// 戻り値は HTTP の状態（通信に失敗したら 0）。apns-direct の Mac でも登録簿を通す（認証は端末トークン）。
    func liveActivityTargets(_ targets: [(token: String, env: String)]) async -> Int {
        guard let deviceToken = KeyStore.deviceToken(), let site = Self.convexSite(),
              let url = URL(string: site + "/v3/live-activity-targets"),
              let data = try? JSONSerialization.data(withJSONObject: Self.liveActivityTargetsBody(targets)) else { return 0 }
        let (status, _, _) = await Self.postLiveActivity(url: url, deviceToken: deviceToken, body: data)
        WebSocketServer.wslog("[LiveActivity] targets status=\(status) count=\(min(targets.count, Self.liveActivityTargetLimit))")
        return status
    }

    /// Live Activity の更新・終わりを 1 件送る（登録簿が APNs の liveactivity push にする）。
    func sendLiveActivity(token: String, env: String, event: String, state: LiveActivityState, timestamp: Int,
                          staleAfterSec: Int?, dismissAfterSec: Int?) async -> LiveActivitySendResult {
        guard let deviceToken = KeyStore.deviceToken(), let site = Self.convexSite(),
              let url = URL(string: site + "/v3/live-activity"),
              let data = try? JSONSerialization.data(withJSONObject: Self.liveActivityBody(
                  token: token, env: env, event: event, state: state, timestamp: timestamp,
                  staleAfterSec: staleAfterSec, dismissAfterSec: dismissAfterSec)) else {
            return LiveActivitySendResult(status: 0)
        }
        let (status, respData, retryAfter) = await Self.postLiveActivity(url: url, deviceToken: deviceToken, body: data)
        let result = Self.liveActivityResult(status: status, data: respData, retryAfter: retryAfter)
        WebSocketServer.wslog("[LiveActivity] push event=\(event) status=\(status) sent=\(result.sent) token=\(token.prefix(8))…")
        return result
    }

    private static func postLiveActivity(url: URL, deviceToken: String, body: Data) async -> (Int, Data, TimeInterval?) {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = body
        TrafficMeter.shared.record("push.la.out", bytes: body.count)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            TrafficMeter.shared.record("push.la.in", bytes: data.count)
            let http = resp as? HTTPURLResponse
            let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) }
            return (http?.statusCode ?? 0, data, retryAfter)
        } catch {
            WebSocketServer.wslog("[LiveActivity] request failed: \(error)")
            return (0, Data(), nil)
        }
    }

    /// 登録簿に登録できる Live Activity の token の数。
    static let liveActivityTargetLimit = 8

    /// `/v3/live-activity-targets` の本文（token の SHA-256 と env。同じ token は 1 つ、8 件まで）。
    static func liveActivityTargetsBody(_ targets: [(token: String, env: String)]) -> [String: Any] {
        var seen = Set<String>()
        var out: [[String: String]] = []
        for t in targets {
            let hash = tokenHash(t.token)
            guard seen.insert(hash).inserted else { continue }
            out.append(["tokenHash": hash, "env": convexEnv(t.env)])
            if out.count >= liveActivityTargetLimit { break }
        }
        return ["targets": out]
    }

    /// `/v3/live-activity` の本文（update は staleAfterSec、end は dismissAfterSec。ほかの項目は付けない）。
    static func liveActivityBody(token: String, env: String, event: String, state: LiveActivityState, timestamp: Int,
                                 staleAfterSec: Int?, dismissAfterSec: Int?) -> [String: Any] {
        var body: [String: Any] = [
            "environment": convexEnv(env),
            "token": token,
            "event": event,
            "timestamp": timestamp,
            "state": ["phase": state.phase, "running": state.running, "failed": state.failed],
        ]
        if event == "update", let staleAfterSec { body["staleAfterSec"] = staleAfterSec }
        if event == "end", let dismissAfterSec { body["dismissAfterSec"] = dismissAfterSec }
        return body
    }

    /// `/v3/live-activity` の応答を読む。
    static func liveActivityResult(status: Int, data: Data, retryAfter: TimeInterval?) -> LiveActivitySendResult {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return LiveActivitySendResult(status: status, sent: obj?["sent"] as? Bool ?? false,
                                      invalid: obj?["invalid"] as? Bool ?? false,
                                      error: obj?["error"] as? String, retryAfter: retryAfter)
    }

    // MARK: - direct モード

    private func sendDirect(token: String, env: String, locale: String, box: E2EBox, didReconfigure: inout Bool) async {
        // direct クライアントは単一環境で構成される。環境不一致 token は BadDeviceToken で
        // valid token を誤って外しかねないため送らない。
        guard env == directEnv else { return }
        struct E2EPayload: Codable {
            let e2e: E2EBox
        }
        let text = Self.placeholder(locale: locale)
        do {
            // 接続系エラー時の再構成・再送は sendDirectWithRecovery。再送も同じ暗号文 box を使う (fail-closed)。
            let sent = try await sendDirectWithRecovery(didReconfigure: &didReconfigure) { c in
                _ = try await c.sendAlertNotification(
                    .init(
                        alert: .init(
                            title: .raw(text.title),
                            subtitle: nil,
                            body: .raw(text.body),
                            launchImage: nil
                        ),
                        expiration: Self.deliveryExpiration(),
                        priority: .immediately,
                        topic: bundleId,
                        payload: E2EPayload(e2e: box),
                        sound: .default,
                        // mutable-content: iOS の NSE を起動させて復号・表示差し替えを行う（§14.3）
                        mutableContent: 1,
                        interruptionLevel: .timeSensitive
                    ),
                    deviceToken: token
                )
            }
            guard sent else { return }
            WebSocketServer.wslog("[PushService] sent e2e token=\(token.prefix(8))…")
        } catch {
            WebSocketServer.wslog("[PushService] e2e send failed token=\(token.prefix(8))… error=\(error)")
            if Self.isInvalidTokenError(error) {
                devices.clearPush(token: token)
                WebSocketServer.wslog("[PushService] removed invalid e2e token")
            }
        }
    }

    /// direct 送信を 1 件実行する。
    /// ネットワーク切替 (テザリング↔Wi-Fi) で APNs クライアントの接続が壊れ "Network is down"
    /// になることがある。接続系エラーなら APNs クライアントを作り直して、この 1 件だけを再送する。
    /// 再構成は broadcast 1 回につき 1 度まで (`didReconfigure` を呼び出し元で共有)。
    /// 戻り値: 送れたら true、クライアント未構成で送らなかったら false。最終的な失敗は throw する。
    private func sendDirectWithRecovery(
        didReconfigure: inout Bool,
        _ send: (APNSClient<JSONDecoder, JSONEncoder>) async throws -> Void
    ) async throws -> Bool {
        guard let active = await activeClient() else { return false }
        do {
            try await send(active.client)
            return true
        } catch {
            guard !didReconfigure, Self.isConnectionError(error) else { throw error }
            WebSocketServer.wslog("[PushService] connection error — reconfiguring APNs client (network change?) error=\(error)")
            didReconfigure = true
            await reconfigure(ifGeneration: active.generation)
            guard let retry = await activeClient() else { throw error }
            try await send(retry.client)
            return true
        }
    }

    /// 再構成中ならその完了を待ってから、現役の APNs クライアントとその世代を返す
    /// (shutdown 中の古いクライアントを使ったり、client=nil の瞬間に黙って送信を落としたりしないため)。
    private func activeClient() async -> (client: APNSClient<JSONDecoder, JSONEncoder>, generation: Int)? {
        if let task = reconfigureTask { await task.value }
        guard let client else { return nil }
        return (client, clientGeneration)
    }

    /// ネットワーク切替などで壊れた APNs クライアントを破棄して作り直す。
    /// `generation` は送信に失敗したときのクライアントの世代。actor 再入で複数の broadcast が
    /// 同時に失敗しても再構成は 1 本にまとめ (進行中なら完了を待つ)、既に作り直し済みなら何もしない
    /// — 他の送信が使っている新しいクライアントを shutdown したり、二重生成でリークしたりしないため。
    private func reconfigure(ifGeneration generation: Int) async {
        if let task = reconfigureTask {
            await task.value
            return
        }
        guard generation == clientGeneration else { return }
        let old = client
        client = nil
        clientGeneration += 1
        let task = Task { await self.rebuildClient(shuttingDown: old) }
        reconfigureTask = task
        await task.value
        reconfigureTask = nil
    }

    private func rebuildClient(shuttingDown old: APNSClient<JSONDecoder, JSONEncoder>?) async {
        if let old {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                old.shutdown { _ in cont.resume() }
            }
        }
        configured = false
        configurationError = nil
        await configure()
    }

    /// APNs の保存期限。`.immediately` (apns-expiration: 0) だと配送を 1 回しか試みず、
    /// 圏外の瞬間に出た承認要求・cron 結果が失われる。relay と揃えて 1 時間とする。
    private static func deliveryExpiration() -> APNSNotificationExpiration {
        .timeIntervalSince1970InSeconds(Int(Date().timeIntervalSince1970) + 3600)
    }

    /// 接続系エラー (POSIX/NIO/HTTPClient) か。APNSError は APNs から HTTP 応答が返っている
    /// (429 / 5xx / 403 等) = 接続は生きているので、クライアントを作り直しても直らず再構成しない。
    private static func isConnectionError(_ error: Error) -> Bool {
        !(error is APNSError)
    }

    /// APNs 応答が「このトークンへ送り続けても無駄」と示すものか判定する。
    /// BadDeviceToken / Unregistered / DeviceTokenNotForTopic、または 410 を対象とする。
    private static func isInvalidTokenError(_ error: Error) -> Bool {
        guard let apns = error as? APNSError else { return false }
        if apns.responseStatus == 410 { return true }
        guard let reason = apns.reason else { return false }
        return reason == .badDeviceToken
            || reason == .unregistered
            || reason == .deviceTokenNotForTopic
    }
}

/// `/v3/live-activity` の応答。
struct LiveActivitySendResult: Equatable, Sendable {
    /// HTTP の状態（通信に失敗したら 0）
    var status: Int
    /// 200 のときの `sent`
    var sent = false
    /// 200 のときの `invalid`（APNs が無効と答えた token）
    var invalid = false
    /// 403 の `error`（unknown_token・revoked）
    var error: String?
    /// 429 の `Retry-After`（秒）
    var retryAfter: TimeInterval?
}
