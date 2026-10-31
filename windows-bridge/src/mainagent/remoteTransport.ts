import http from "node:http";

// 別の PC（B）の Bridge へ道具を送る口。
// Bridge A は別の PC の資格情報（bdc_）を持たない。デスクトップ A が PC ごとに開いた中継口（PaseoProxy）へ、
// 合言葉（bdp_…）を付けて http://127.0.0.1:<port>/device/orchestrator/<tool> を送るだけ（中継口が bdc_ に付け替えて B へ流す）。

/** デスクトップが PUT /local/remote-pcs で渡す 1 台（メモリにだけ持つ。ファイルに書かない）。 */
export interface RemotePc {
  bridgeId: string;
  name: string;
  platform: string;
  /** 中継口の番号（127.0.0.1）。 */
  port: number;
  /** 中継口の合言葉（bdp_…。アプリを起動するたびに変わる）。 */
  secret: string;
}

export interface RemoteResponse {
  status: number;
  body: string;
}

/** B へ 1 件送る（テストは差し替える）。本文は JSON の文字列。 */
export type RemoteTransport = (pc: RemotePc, tool: string, body: string, timeoutMs: number) => Promise<RemoteResponse>;

const MAX_RESPONSE_BYTES = 4 * 1024 * 1024;

export const httpRemoteTransport: RemoteTransport = (pc, tool, body, timeoutMs) =>
  new Promise((resolve, reject) => {
    const req = http.request(
      {
        host: "127.0.0.1",
        port: pc.port,
        path: `/device/orchestrator/${encodeURIComponent(tool)}`,
        method: "POST",
        headers: {
          "content-type": "application/json",
          accept: "application/json",
          authorization: `Bearer ${pc.secret}`,
          "content-length": Buffer.byteLength(body)
        }
      },
      (res) => {
        const chunks: Buffer[] = [];
        let size = 0;
        res.on("data", (c: Buffer) => {
          size += c.length;
          if (size > MAX_RESPONSE_BYTES) {
            req.destroy(new Error("応答が大きすぎる"));
            return;
          }
          chunks.push(c);
        });
        res.on("end", () => resolve({ status: res.statusCode ?? 0, body: Buffer.concat(chunks).toString("utf8") }));
        res.on("error", reject);
      }
    );
    // 返事を待つ道具（wait_seconds）は B が待つので、A はそれより 30 秒長く待ってから打ち切る（呼ぶ側が決める）。
    req.setTimeout(timeoutMs, () => req.destroy(new Error(`${Math.round(timeoutMs / 1000)} 秒で応答が無かった`)));
    req.on("error", reject);
    req.end(body);
  });

/**
 * PUT /local/remote-pcs の本文 `{"pcs":[{bridgeId,name,platform,port,secret}]}` を読む。形が違えば undefined（まるごと断る）。
 * 同じ bridgeId が 2 つあれば後のものを使う。
 */
export function parseRemotePcs(value: unknown): RemotePc[] | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const list = (value as { pcs?: unknown }).pcs;
  if (!Array.isArray(list)) return undefined;
  const byId = new Map<string, RemotePc>();
  for (const raw of list) {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) return undefined;
    const r = raw as Record<string, unknown>;
    const str = (k: string): string | undefined => (typeof r[k] === "string" && (r[k] as string).trim() ? (r[k] as string).trim() : undefined);
    const bridgeId = str("bridgeId");
    const secret = typeof r.secret === "string" && r.secret ? r.secret : undefined;
    const port = r.port;
    if (!bridgeId || !secret || typeof port !== "number" || !Number.isInteger(port) || port < 1 || port > 65535) return undefined;
    byId.set(bridgeId, { bridgeId, name: str("name") ?? bridgeId.slice(0, 8), platform: str("platform") ?? "unknown", port, secret });
  }
  return [...byId.values()];
}
