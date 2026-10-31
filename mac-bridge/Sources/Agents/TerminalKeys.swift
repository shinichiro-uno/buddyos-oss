import Darwin
import Foundation

// ---------------------------------------------------------------------------
// ターミナルの対話画面（TUI）に出た選択肢へ、キー入力で答える
//
// ターミナルで動いている Claude Code の選択肢（許可確認・AskUserQuestion・計画の承認）は、
// hook で中身は分かるが、答える公式の口は channel の許可中継（許可確認だけ）しかない。
// BuddyOS のデスクトップアプリが開いたターミナル（node-pty）なら、選んだ内容をキー入力に
// 直して書き込めば答えられる（Orca と同じ方式）。
//
//   デスクトップ（main プロセス）: GET /terminal/keys/poll?pids=… で、自分が持っている pty の pid を
//     名乗りながら long-poll する。返ってきたキーを、その pty に gapMs おきに書く。
//   Bridge: 選択肢を出した claude の pid から親をたどり、名乗られた pty の pid に行き当たれば
//     「キーで答えられる」とみなしてカードを出す。答えが来たらキーを積む。
//
// キー手順は Claude Code 2.1.285 の画面で実測（tmux）:
//   許可確認        1. Yes / 2. Yes, and don't ask again（候補があるときだけ）/ 3. No、Esc で取り消し
//   AskUserQuestion 単一選択は番号で選んで次の問いへ進む。最後の番号（N+1）が「Type something」で、
//                   文字を打って Enter。複数選択は番号で印を付け外しし、→ で次へ。
//                   質問が 2 つ以上か複数選択があると最後に確認画面が出て、Enter（1. Submit answers）で送る
//   計画の承認      1. Yes, auto-accept edits / 2. Yes, manually approve edits /
//                   3. Tell Claude what to change（3 で入力欄に移り、文字を打って Enter）
//   受け箱の保留    Deny — drop it and tell the sender it was declined（最初に選ばれている）/
//                   Deliver this message to Claude。番号は無く番号キーでは選べず、↑↓ は端で折り返す。
//                   ↓ Enter で Deliver、Esc で Deny（届かない）
//                   （YOLO のセッションがほかから届いた発話を止めたときのダイアログ。claude 2.1.293 で実測）
// 番号と Enter を一度に送ると選ぶ前に確定してしまうので、1 操作ずつ間をあけて送る。
//
// 人が iPhone・デスクトップの入力欄で打った発話も、同じ口でターミナルに打ち込む（TerminalKeyPlan.typing）。
// 受け箱（cross-session messaging）で送ると「別の Claude セッションからの依頼」として届き、本人の承認として
// 扱われない。打ち込めばキーボードで打ったのと同じ発話になる（docs/PTY_TYPING_2026-10-23.md）。
// 打ち込みは、宛先の claude が生きていて前面にいるかを書く前に確かめるデスクトップ（poll の typing=1）にだけ送る。
// ---------------------------------------------------------------------------

/// デスクトップの pty へキーを届ける受け渡し口。
/// 取りに来る相手（client = ターミナルの常駐プロセス。開発版と製品版で別）ごとに、持っている pty と受け箱を分ける。
actor TerminalKeyRouter {
    static let shared = TerminalKeyRouter()

    struct Delivery: Sendable {
        let pid: Int32
        let keys: [String]
        let gapMs: Int
        /// 発話の打ち込みの宛先の claude の pid。デスクトップは書く前に、これが生きていてターミナルの前面にいるかを確かめ、
        /// 違えば残りを書かない（claude が終わった後や Ctrl+Z で止めた後のシェルに、発話をコマンドとして打たない）。
        var expectPid: Int32? = nil
        /// その claude の session id。デスクトップは書く前に毎回 ~/.claude/sessions/<expectPid>.json を読み、この session で
        /// status が idle のときだけ書く（貼り付けている間に許可の確認や一覧が開いたら、Enter で選ばない）。
        var expectSession: String? = nil
    }

    private struct Client {
        var pids: Set<Int32> = []
        /// 発話の打ち込みを受け付けるか（expectPid を確かめてから書くデスクトップ。poll の typing=1）。
        var canType = false
        var lastSeen = Date()
        var queue: [Delivery] = []
        var waiter: (token: UUID, continuation: CheckedContinuation<[Delivery], Never>)?
        /// 直近で取りに来ているか（poll は返った直後に張り直すので隙間は短い）。
        var isConnected: Bool { waiter != nil || Date().timeIntervalSince(lastSeen) < 10 }
    }

    private var clients: [String: Client] = [:]

    /// claude 本体の pid から親をたどり、デスクトップが持っている pty の pid を返す（無ければ nil）。
    func ptyOwner(of pid: Int32?) -> Int32? {
        owner(of: pid) { _ in true }
    }

    /// 発話を打ち込める pty（打ち込みを受け付けるデスクトップが持っているもの）の pid。無ければ nil。
    func typingOwner(of pid: Int32?) -> Int32? {
        owner(of: pid) { $0.canType }
    }

    private func owner(of pid: Int32?, where match: (Client) -> Bool) -> Int32? {
        guard let pid else { return nil }
        let owned = clients.values.filter { $0.isConnected && match($0) }.reduce(into: Set<Int32>()) { $0.formUnion($1.pids) }
        guard !owned.isEmpty else { return nil }
        var cur = pid
        for _ in 0..<8 {
            if owned.contains(cur) { return cur }
            guard let parent = Self.parentPid(of: cur), parent > 1, parent != cur else { return nil }
            cur = parent
        }
        return nil
    }

    func enqueue(_ delivery: Delivery) {
        guard let key = clients.first(where: { $0.value.isConnected && $0.value.pids.contains(delivery.pid) })?.key,
              var c = clients[key] else { return }
        if let w = c.waiter {
            c.waiter = nil
            clients[key] = c
            w.continuation.resume(returning: [delivery])
        } else {
            c.queue.append(delivery)
            clients[key] = c
        }
    }

    /// デスクトップの long-poll。pids は今開いている pty の pid（毎回まるごと名乗る）。
    /// canType は発話の打ち込みを受け付けるか（古いデスクトップは名乗らないので、選択肢への答えだけを送る）。
    func poll(client: String, pids: [Int32], canType: Bool = false, timeout: TimeInterval) async -> [Delivery] {
        var c = clients[client] ?? Client()
        c.pids = Set(pids)
        c.canType = canType
        c.lastSeen = Date()
        if !c.queue.isEmpty {
            let q = c.queue
            c.queue.removeAll()
            clients[client] = c
            return q
        }
        let old = c.waiter
        c.waiter = nil
        clients[client] = c
        old?.continuation.resume(returning: [])
        let token = UUID()
        let result = await withCheckedContinuation { (cont: CheckedContinuation<[Delivery], Never>) in
            clients[client]?.waiter = (token, cont)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.expire(client: client, token: token)
            }
        }
        clients[client]?.lastSeen = Date()
        return result
    }

    private func expire(client: String, token: UUID) {
        guard let w = clients[client]?.waiter, w.token == token else { return }
        clients[client]?.waiter = nil
        w.continuation.resume(returning: [])
    }

    static func parentPid(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}

/// 選んだ答え → Claude Code の TUI へ送るキーの列（1 要素 = 1 操作。間をあけて送る）。
enum TerminalKeyPlan {
    static let esc = "\u{1b}"
    static let enter = "\r"
    static let right = "\u{1b}[C"
    static let down = "\u{1b}[B"

    /// 新しい会話（/new）。`/clear` を打ってから Enter（一度に送ると補完の候補を選ぶ前に確定してしまう）。
    static let newConversation = ["/clear", enter]

    static let pasteStart = "\u{1b}[200~"
    static let pasteEnd = "\u{1b}[201~"
    /// 打ち込みの 1 操作の長さ（UTF-16 の数）。デスクトップが受け付ける 8192 より少し短くする。
    static let typingChunk = 8000
    /// デスクトップが 1 回で受け付ける操作の数と、1 操作の長さ（terminalKeyRelay.ts の MAX_KEYS / MAX_KEY_LENGTH）。
    static let relayMaxKeys = 32
    static let relayMaxKeyLength = 8192
    /// 貼り付けから Enter まで（と、長い文を分けた貼り付けの間）の時間。claude 2.1.300 で 500ms なら確実に送られた。
    static let typingGapMs = 500

    /// 人が打った発話を、ターミナルの claude に打ち込むキーの列。貼り付け（bracketed paste）で入れてから Enter。
    /// 空のとき・長すぎてデスクトップが受け付けないときは nil。claude 2.1.300 で実測:
    /// - 改行を含む文も 1 つの発話になる。長い文は貼り付けの途中で分けても、閉じる印までが 1 つの貼り付けになる。
    /// - 長い文・行の多い文は、ターミナルで貼り付けたときと同じく `<pasted_content>` に包まれて届く。
    /// - 先頭が `/` の文は、コマンド名でなければ普通の発話になる。`@` はファイルの指定として読まれる（打ったときと同じ）。
    /// - 先頭が `!` だと、シェルのコマンドとしてすぐ実行される（bash モード。許可の確認も auto の判定も通らない）。
    ///   空白を 1 つ前に付けると普通の発話になるので、そうして Claude に渡す。
    static func typing(_ text: String) -> [String]? {
        var body = sanitizedForTyping(text)
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if body.hasPrefix("!") { body = " " + body }
        // 文字（書記素）の途中では分けない（サロゲートの片方だけを書くと、デスクトップで文字化けする）。
        var chunks: [String] = []
        var current = pasteStart
        // 長さは足しながら数える（毎回 utf16.count を数え直すと、長い文で遅くなる）。
        var length = pasteStart.utf16.count
        for ch in body {
            let n = ch.utf16.count
            if length + n > typingChunk, length > 0 {
                chunks.append(current)
                current = ""
                length = 0
            }
            current.append(ch)
            length += n
        }
        if length + pasteEnd.utf16.count > typingChunk {
            chunks.append(current)
            current = ""
        }
        chunks.append(current + pasteEnd)
        guard chunks.count < relayMaxKeys, chunks.allSatisfy({ $0.utf16.count <= relayMaxKeyLength }) else { return nil }
        return chunks + [enter]
    }

    /// 打ち込む文から制御文字を落とす（改行とタブは残す）。ESC を通すと貼り付けを途中で閉じ、続きをキー操作として
    /// 打たせられる（`ESC [201~` の後ろの文字や Enter）。改行は \n にそろえる（\r は Enter として送られてしまう）。
    static func sanitizedForTyping(_ text: String) -> String {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var kept = String.UnicodeScalarView()
        for s in unified.unicodeScalars where s == "\n" || s == "\t" || !(s.value < 0x20 || (0x7F...0x9F).contains(s.value)) {
            kept.append(s)
        }
        return String(kept)
    }

    /// 許可確認。allow → 1、allowForSession → 2（候補があるときだけ画面にある）、それ以外 → Esc。
    static func approval(decision: String, hasSuggestions: Bool) -> [String] {
        switch decision {
        case "allow": return ["1"]
        case "allowForSession": return [hasSuggestions ? "2" : "1"]
        default: return [esc]
        }
    }

    /// 受け箱の保留。allow → ↓ Enter（Deliver）、それ以外 → Esc（Deny）。
    static func held(decision: String) -> [String] {
        decision.hasPrefix("allow") ? [down, enter] : [esc]
    }

    /// 計画の承認。allowAuto → 1、allow → 2、deny → Esc（計画モードのまま止める）、
    /// それ以外の文 → 3 で入力欄に移ってその文を打ち、Enter。
    static func plan(decision: String) -> [String] {
        switch decision {
        case "allowAuto": return ["1"]
        case "allow": return ["2"]
        case "deny": return [esc]
        default:
            let text = decision.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [esc] : ["3", text, enter]
        }
    }

    /// AskUserQuestion。answers は 質問文 → 選んだ label（複数選択は配列）。選択肢に無い文は「Type something」で打つ。
    /// 答えが無い質問は最初の選択肢にしない（勝手に選ばない）。代わりに Esc で取り消す。
    static func questions(_ qs: [[String: Any]], answers: [String: [String]]) -> [String]? {
        var keys: [String] = []
        var needsSubmit = qs.count > 1
        for q in qs {
            let question = (q["question"] as? String) ?? ""
            let labels = ((q["options"] as? [[String: Any]]) ?? []).map { ($0["label"] as? String) ?? "" }
            let picked = answers[question] ?? []
            guard !picked.isEmpty else { return nil }
            if (q["multiSelect"] as? Bool) == true {
                needsSubmit = true
                for p in picked {
                    // 複数選択の自由記述は画面の操作が安定しないので送らない（選択肢だけ反映する）。
                    if let i = labels.firstIndex(of: p), i < 9 { keys.append(String(i + 1)) }
                }
                keys.append(right)
            } else {
                let p = picked[0]
                if let i = labels.firstIndex(of: p), i < 9 {
                    keys.append(String(i + 1))
                } else if labels.count < 9 {
                    keys.append(contentsOf: [String(labels.count + 1), p, enter])
                } else {
                    return nil
                }
            }
        }
        if needsSubmit { keys.append(enter) }
        return keys
    }

    /// answers_json（{ 質問 id: 文字列 | [文字列] }）を 質問 → 選んだもの の形に。
    static func answerLists(_ meta: [String: String], fallback decision: String, questions qs: [[String: Any]]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        if let raw = meta["answers_json"], let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in obj {
                if let s = v as? String, !s.isEmpty { out[k] = [s] }
                else if let a = v as? [Any] { out[k] = a.compactMap { $0 as? String }.filter { !$0.isEmpty } }
            }
        }
        // 古いクライアントは最初の質問の答えを decision だけで返す。
        if out.isEmpty, let first = qs.first?["question"] as? String, !decision.isEmpty {
            out[first] = decision.components(separatedBy: ", ").filter { !$0.isEmpty }
        }
        return out
    }
}
