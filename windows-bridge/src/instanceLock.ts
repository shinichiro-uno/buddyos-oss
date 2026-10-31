import crypto from "node:crypto";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";

/**
 * 同じ設定フォルダの Bridge を 1 つだけにする鍵（鍵・ペアリングを共有するので、2 つ動くと iPhone の接続先が揺れる）。
 * Windows は名前付きパイプ、それ以外は Unix ソケットを待ち受けて取り合う。名前付きパイプは持ち主が終わると OS が
 * 消すので、落ちた Bridge の鍵が残って次が起動できなくなることはない（PID ファイルは、Windows だと番号がすぐ
 * 使い回されて当てにならない）。
 */
export interface InstanceLock {
  release(): void;
}

export function lockPath(configDir: string): string {
  const id = crypto.createHash("sha256").update(path.resolve(configDir)).digest("hex").slice(0, 16);
  if (process.platform === "win32") return `\\\\.\\pipe\\buddyos-bridge-${id}`;
  // Unix ソケットは設定フォルダ（0700）の中に置く（全員が書ける /tmp だと、別のユーザーが先に作って横取りできる）。
  // Unix ソケットのパスは 104 バイト前後までなので、収まらないときだけ従来の一時フォルダを使う。
  const inConfig = path.join(path.resolve(configDir), "bridge.lock");
  return Buffer.byteLength(inConfig) <= 100 ? inConfig : path.join(os.tmpdir(), `buddyos-bridge-${id}.sock`);
}

/** 取れたら鍵、ほかの Bridge が持っていたら null。鍵を作れない環境では起動を止めない（何もしない鍵を返す）。 */
export async function acquireInstanceLock(configDir: string): Promise<InstanceLock | null> {
  const where = lockPath(configDir);
  for (let attempt = 0; attempt < 2; attempt++) {
    const server = net.createServer((socket) => socket.destroy());
    const err = await new Promise<NodeJS.ErrnoException | null>((resolve) => {
      server.once("error", resolve);
      server.listen(where, () => resolve(null));
    });
    if (!err) {
      server.unref();
      return { release: () => server.close() };
    }
    if (err.code !== "EADDRINUSE") {
      console.error(`[bridge] instance lock unavailable (${err.code ?? err.message}); continuing without it`);
      return { release: () => {} };
    }
    // Unix は落ちた Bridge のソケットファイルが残る。つながらなければ古いものなので、消して取り直す。
    if (process.platform === "win32" || (await isListening(where))) return null;
    try {
      fs.unlinkSync(where);
    } catch {
      /* 取り直しで分かる */
    }
  }
  return null;
}

function isListening(where: string): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = net.connect(where);
    const done = (ok: boolean) => {
      socket.destroy();
      resolve(ok);
    };
    socket.setTimeout(1000, () => done(false));
    socket.once("connect", () => done(true));
    socket.once("error", () => done(false));
  });
}

/**
 * 実際に待ち受けた番号と自分の PID を設定フォルダに書く（デスクトップアプリやツールが Bridge を見つけるため）。
 * 終わるときは、中身が自分のものなら消す。
 */
export function writeRuntimeFiles(configDir: string, port: number): void {
  const files: Array<[string, string]> = [
    [path.join(configDir, "bridge.port"), String(port)],
    [path.join(configDir, "bridge.pid"), String(process.pid)]
  ];
  for (const [file, value] of files) {
    try {
      fs.writeFileSync(file, value, { mode: 0o600 });
    } catch (error) {
      console.error(`[bridge] could not write ${path.basename(file)}: ${String(error)}`);
    }
  }
  process.once("exit", () => {
    for (const [file, value] of files) {
      try {
        if (fs.readFileSync(file, "utf8").trim() === value) fs.unlinkSync(file);
      } catch {
        /* 消せなくても、次の Bridge が上書きする */
      }
    }
  });
}
