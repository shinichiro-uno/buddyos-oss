import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test, { after } from "node:test";

// 実ホームの ~/.buddyos に書かないよう、ホームを一時ディレクトリに向けてから読み込む。
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-wb-attach-"));
process.env.HOME = tmp;
process.env.USERPROFILE = tmp;

const store = await import("./attachmentStore.js");
const { imageAttachments, imagePlaceholder } = await import("./types.js");

after(() => fs.rmSync(tmp, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 }));

const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 9, 9]).toString("base64");
const inbound = {
  type: "user_message" as const,
  content: "見て",
  metadata: { attachment_count: "2", attachment_0_kind: "image", attachment_0_name: "a.png", attachment_0_mime: "image/png", attachment_0_b64: png, attachment_1_kind: "file", attachment_1_name: "n.txt", attachment_1_b64: "eA==" }
};

test("送った画像を保管し、履歴の目印から実画像に戻す", () => {
  const [image] = imageAttachments(inbound);
  assert.equal(imageAttachments(inbound).length, 1, "ファイルの添付は画像に数えない");
  assert.equal(imagePlaceholder(image), '[image "a.png" attached: image/png, 6 bytes]');
  store.putImage(image);
  const restored = store.restoreHistoryImages({ role: "user", messageId: "m", content: `${imagePlaceholder(image)}\n\n見て` });
  assert.equal(restored.content, "見て");
  assert.deepEqual(restored.attachments, [{ kind: "image", name: "a.png", mime: "image/png", b64: png }]);
  assert.deepEqual(store.historyAttachmentMetadata(restored.attachments), {
    attachment_count: "1",
    attachment_0_kind: "image",
    attachment_0_name: "a.png",
    attachment_0_mime: "image/png",
    attachment_0_b64: png
  });
  // ファイルで渡した CLI 向けのパスの注記も一緒に消える。
  const withPath = store.restoreHistoryImages({ role: "user", messageId: "m", content: `${imagePlaceholder(image)} (file: C:\\x\\a.png — open this file to see the image)\n\n見て` });
  assert.equal(withPath.content, "見て");
  // 保管していない画像は目印のまま残す。
  const unknown = store.restoreHistoryImages({ role: "user", messageId: "m", content: '[image "b.png" attached: image/png, 3 bytes]\n\nx' });
  assert.equal(unknown.attachments.length, 0);
  assert.ok(unknown.content.startsWith("[image"));
});

test("CLI 向けに拡張子つきで書き出す（同じ中身なら同じパス）", () => {
  const [image] = imageAttachments(inbound);
  const file = store.exportImageFile(image)!;
  assert.ok(file.startsWith(store.attachmentExportDir()));
  assert.ok(file.endsWith(".png"));
  assert.equal(store.exportImageFile(image), file);
  assert.equal(fs.readFileSync(file).toString("base64"), png);
});
