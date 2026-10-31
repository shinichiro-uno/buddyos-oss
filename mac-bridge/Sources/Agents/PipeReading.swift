import Foundation

// 子プロセスのパイプを協調スレッドプールを塞がずに読むための部品（ClaudeCodeSession と同じ方式）。
//
// - Task 上で availableData のブロッキング読みを回すと、同時に走るセッション数がコア数に
//   達した時点で Bridge 全体の async 処理（WS / HTTP / SessionHub）が止まる。
//   readabilityHandler（GCD）で受けて AsyncStream に流す。
// - chunk の境界は UTF-8 の文字境界と一致しない。chunk ごとに String(data:encoding:) で
//   デコードすると、多バイト文字の途中で切れた chunk が nil になって丸ごと失われる。
//   Data のまま改行で切ってから行単位でデコードする（不正なバイトは U+FFFD）。

/// 一度だけ立つ通知（子プロセスの終了・stdin への書き込み完了など）。プロセス終了なら、run() の前に
/// 設定した terminationHandler から signal() し、wait() で待つ。
/// waitUntilExit() は呼んだスレッドを塞ぐので、協調スレッドプール上では使わない。
final class OneShotSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        lock.lock()
        fired = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if fired {
                lock.unlock()
                c.resume()
                return
            }
            waiters.append(c)
            lock.unlock()
        }
    }
}

/// stderr を常時読み、末尾だけ保持する。終了時にしか読まないと、長く動く子プロセスでは
/// パイプ容量を超えたところで子の write がブロックする。
final class PipeTailBuffer: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var data = Data()
    private var eof = false

    init(limit: Int = 16 * 1024) {
        self.limit = limit
    }

    /// process.run() 成功後に呼ぶ。
    func start(_ handle: FileHandle) {
        handle.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            if chunk.isEmpty {
                h.readabilityHandler = nil
                self?.markEOF()
            } else {
                self?.append(chunk)
            }
        }
    }

    private func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        if data.count > limit { data = Data(data.suffix(limit)) }
    }

    private func markEOF() {
        lock.lock(); eof = true; lock.unlock()
    }

    var isEOF: Bool {
        lock.lock(); defer { lock.unlock() }
        return eof
    }

    /// 別スレッドで読んでいる最後の出力が届くのを短時間だけ待つ（プロセス終了後に使う）。
    func waitForEOF(timeout: TimeInterval = 0.5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !isEOF, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

enum PipeChunks {
    /// readabilityHandler で読んだ chunk を流す。EOF で handler を外して終える。
    /// process.run() 成功後に呼ぶ（無効 fd へ dispatch source を張らないため）。
    static func stream(_ handle: FileHandle) -> AsyncStream<Data> {
        let (chunks, sink) = AsyncStream.makeStream(of: Data.self)
        handle.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty {
                h.readabilityHandler = nil
                sink.finish()
            } else {
                sink.yield(chunk)
            }
        }
        return chunks
    }
}

/// Data を改行 (0x0A) で切り出し、行ごとに UTF-8 デコードする。
struct PipeLineSplitter {
    private var buffer = Data()
    /// buffer 先頭から改行が無いと確認済みのバイト数（巨大な行で毎回先頭から探さない）。
    private var scanned = 0

    /// 完成した行（改行は含まない）を返す。改行で終わらない末尾は次の chunk まで持ち越す。
    mutating func feed(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var lines: [String] = []
        var lineStart = buffer.startIndex
        var searchFrom = buffer.startIndex + scanned
        while let newline = buffer[searchFrom...].firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[lineStart..<newline], as: UTF8.self))
            lineStart = buffer.index(after: newline)
            searchFrom = lineStart
        }
        buffer.removeSubrange(buffer.startIndex..<lineStart)
        scanned = buffer.count
        return lines
    }
}

/// 行ではなく生テキストを逐次流す出力向けの増分 UTF-8 デコーダ。chunk の末尾で切れた
/// 多バイト文字（最大 3 バイト）を次の chunk へ持ち越す。不正なバイトは U+FFFD にする。
struct IncrementalUTF8Decoder {
    private var pending: [UInt8] = []

    mutating func decode(_ chunk: Data) -> String {
        pending.append(contentsOf: chunk)
        let cut = Self.completePrefixLength(pending)
        let text = String(decoding: pending[..<cut], as: UTF8.self)
        pending.removeFirst(cut)
        return text
    }

    /// 持ち越したまま終わった断片（EOF 時）。
    mutating func flush() -> String {
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }

    /// 末尾の途中で切れた多バイト文字を除いた長さ。
    private static func completePrefixLength(_ bytes: [UInt8]) -> Int {
        var i = bytes.count - 1
        var back = 0
        while i >= 0, back < 4 {
            let b = bytes[i]
            if b & 0xC0 != 0x80 {
                // 先頭バイト。後続が揃っていなければ、ここから次の chunk へ持ち越す。
                let need: Int
                if b < 0x80 { need = 1 }
                else if b & 0xE0 == 0xC0 { need = 2 }
                else if b & 0xF0 == 0xE0 { need = 3 }
                else if b & 0xF8 == 0xF0 { need = 4 }
                else { need = 1 }   // 不正な先頭バイトはそのまま U+FFFD にさせる
                return bytes.count - i < need ? i : bytes.count
            }
            i -= 1
            back += 1
        }
        return bytes.count
    }
}
