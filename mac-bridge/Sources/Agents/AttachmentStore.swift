import Foundation
import CryptoKit

/// 送信された画像添付を bridge ローカルに保管し、履歴復元時に実画像へ戻すためのサイドカー。
///
/// 背景: Claude Code はモデルへ画像を渡せず、プロンプト本文に
/// `[image "<name>" attached: <mime>, <N> bytes]` というテキスト placeholder を書く。
/// その結果、履歴（Claude のトランスクリプト / bridge ローカル store のどちら経由でも）は
/// 画像が文字列化してしまう。送信時にバイトをここへ保管し、`loadHistory` で placeholder と
/// 突き合わせて実画像に復元する。
///
/// key = `<name>|<byteCount>|<mime>`。placeholder が name/mime/size を完全に含むので、
/// sessionId を跨いだ rebind（claude の sessionId 確定遅延）に依存せず join できる。
actor AttachmentStore {
    static let shared = AttachmentStore()

    private let dir: URL
    /// 保持する最大ファイル数（古い順に prune）。1 枚あたり縮小済み JPEG 数百 KB 想定。
    private let maxFiles = 500

    init() {
        dir = BuddyPaths.root.appendingPathComponent("attachments")
    }

    static func key(name: String, byteCount: Int, mime: String) -> String {
        "\(name)|\(byteCount)|\(mime)"
    }

    private func filename(forKey key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".img"
    }

    /// 画像バイトを保管（既存なら更新日時だけ touch して prune 生存を延ばす）。
    func put(name: String, mime: String, data: Data) {
        let key = Self.key(name: name, byteCount: data.count, mime: mime)
        let url = dir.appendingPathComponent(filename(forKey: key))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            } else {
                try data.write(to: url, options: .atomic)
            }
            prune(dir)
        } catch {
            FileHandle.standardError.write(Data("[AttachmentStore] put failed: \(error.localizedDescription)\n".utf8))
        }
    }

    /// 画像を渡す手段がファイルしかない CLI（cursor / grok / agy の headless 実行）へ渡すため、
    /// 拡張子つきのファイルとして書き出してパスを返す。中身が同じなら同じパス（書き直さない）。
    func exportFile(name: String, mime: String, data: Data) -> URL? {
        let dir = Self.exportDirectory
        let key = Self.key(name: name, byteCount: data.count, mime: mime)
        let base = String(filename(forKey: key).prefix(24))
        let url = dir.appendingPathComponent(base + "." + Self.fileExtension(mime: mime, name: name))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            } else {
                try data.write(to: url, options: .atomic)
            }
            prune(dir)
            return url
        } catch {
            FileHandle.standardError.write(Data("[AttachmentStore] export failed: \(error.localizedDescription)\n".utf8))
            return nil
        }
    }

    /// exportFile の置き場所。agy はワークスペースの外を読めないので、この場所を --add-dir で渡す。
    static var exportDirectory: URL {
        BuddyPaths.root
            .appendingPathComponent("attachments")
            .appendingPathComponent("files")
    }

    static func fileExtension(mime: String, name: String) -> String {
        switch mime.lowercased() {
        case "image/png": return "png"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        default:
            let ext = (name as NSString).pathExtension.lowercased()
            return ext.isEmpty ? "bin" : ext
        }
    }

    /// placeholder の (name, byteCount, mime) から保管済みバイトを引く。
    func lookup(name: String, byteCount: Int, mime: String) -> Data? {
        let key = Self.key(name: name, byteCount: byteCount, mime: mime)
        let url = dir.appendingPathComponent(filename(forKey: key))
        return try? Data(contentsOf: url)
    }

    /// 上限超過分を更新日時の古い順に削除。
    private func prune(_ dir: URL) {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ), items.count > maxFiles else { return }
        let sorted = items.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        for url in sorted.prefix(items.count - maxFiles) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
