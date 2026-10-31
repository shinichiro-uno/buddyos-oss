import type http from "node:http";

// ブラウザ（プレビュー中のページ・別のサイト）から Bridge の API に届かないようにする関門。
// 約束は mac-bridge の BridgeRequestGuard.swift・desktop と同じ（
// 値は shared/preview-auth-vectors.json で 3 実装をそろえている）。
// - Host（全ルート。/preview/* も含む）: 1 本だけで、名前が 127.0.0.1 / localhost / [::1] のどれか
//   （DNS rebinding で別の名前から来た要求を断る）。番号は見ない。Paseo の中継から来る要求は、
//   iPhone 側の 127.0.0.1:<端末の中の番号> を Host に載せて届くため。
// - Origin: 付いていなければ通す（iOS / Android / CLI の hook はブラウザではないので付けない）。付いているなら
//   デスクトップアプリの画面だけが付ける "buddyos-desktop://app" と完全に一致するときだけ通す。
//   "null"（sandbox の iframe）・http://localhost:* ・http://127.0.0.1:* ・file:// などは全部断る。
//   プレビューのセッションで認証するルート（中継したページから Origin: null で届く）だけはこの判定の外。
// 認証（Bearer の apiKey）が本来の確認で、これは CSRF・DNS rebinding・プレビューを切り離すための追加の層。

export const DESKTOP_ORIGIN = "buddyos-desktop://app";

const LOOPBACK_HOSTNAMES = new Set(["127.0.0.1", "localhost", "[::1]"]);

export type GuardRejection = "forbidden_host" | "forbidden_origin";

/** ヘッダの全部の行。Node は Host の 2 本目を捨て、Origin は ", " でつなぐので、headersDistinct があればそちらを見る。 */
function headerValues(req: http.IncomingMessage, name: "host" | "origin"): string[] {
  const distinct = (req as { headersDistinct?: Record<string, string[] | undefined> }).headersDistinct?.[name];
  if (distinct) return distinct;
  const value = req.headers[name];
  return value === undefined ? [] : [value];
}

/** Origin の行が無いか、ちょうど 1 本でデスクトップアプリの画面の Origin と完全に一致するか。 */
export function allowedOriginValues(values: readonly string[]): boolean {
  if (values.length === 0) return true;
  return values.length === 1 && values[0] === DESKTOP_ORIGIN;
}

/** Host の行がちょうど 1 本で、名前が 127.0.0.1 / localhost / [::1]（番号は任意）か。 */
export function allowedHostValues(values: readonly string[]): boolean {
  if (values.length !== 1) return false;
  const host = values[0].trim().toLowerCase();
  if (!host) return false;
  const m = /^(\[[^\]]*\]|[^:]+)(?::(\d{1,5}))?$/.exec(host);
  if (!m) return false;
  if (m[2] !== undefined && Number(m[2]) > 65535) return false;
  return LOOPBACK_HOSTNAMES.has(m[1]);
}

/** Origin が無いか、デスクトップアプリの画面の Origin と完全に一致するか。 */
export function allowedOrigin(req: http.IncomingMessage): boolean {
  return allowedOriginValues(headerValues(req, "origin"));
}

/** Host が 127.0.0.1 / localhost / [::1]（番号は任意）か。Host が無い・2 本以上ある要求は断る。 */
export function allowedHost(req: http.IncomingMessage): boolean {
  return allowedHostValues(headerValues(req, "host"));
}

/** Origin と Host の両方を満たすか。 */
export function passesOriginGuard(req: http.IncomingMessage): boolean {
  return allowedOrigin(req) && allowedHost(req);
}

/**
 * ルーターと同じ見方でパスを要素に分ける（URL として正規化した pathname を `/` で分け、空の要素は捨て、
 * 各要素の %エンコードを戻す）。"/preview/../ws/agent/x" は /ws/agent/x として見る。読めない URL は null。
 */
export function pathComponents(rawUrl: string | undefined): string[] | null {
  let pathname: string;
  try {
    pathname = new URL(rawUrl ?? "/", "http://localhost").pathname;
  } catch {
    return null;
  }
  return pathname.split("/").filter((c) => c.length > 0).map((c) => {
    try {
      return decodeURIComponent(c);
    } catch {
      return c;
    }
  });
}

/**
 * プレビューのセッションで認証するルートか（Origin の判定をかけない）。
 *   /preview/ui, /preview/sim/{stream,tap,swipe}, /preview/w/<session>[/**]
 * Windows に sim は無いが、判定は mac と同じにしておく（どちらにしても sim のルートは 404）。
 */
export function isPreviewSessionPath(rawUrl: string | undefined): boolean {
  const comps = pathComponents(rawUrl);
  if (!comps || comps[0] !== "preview" || comps.length < 2) return false;
  switch (comps[1]) {
    case "ui":
      return comps.length === 2;
    case "sim":
      return comps.length === 3 && ["stream", "tap", "swipe"].includes(comps[2]);
    case "w":
      return comps.length >= 3;
    default:
      return false;
  }
}

/** 断る理由（通すなら null）。全 HTTP ルートと全 WebSocket の upgrade で、本文を読む前に見る。 */
export function guardRejection(req: http.IncomingMessage): GuardRejection | null {
  if (!allowedHost(req)) return "forbidden_host";
  if (isPreviewSessionPath(req.url)) return null;
  if (!allowedOrigin(req)) return "forbidden_origin";
  return null;
}

/** 関門で断ったときの本文（mac の BridgeRequestGuard.forbidden と同じ）。 */
export function forbiddenBody(error: GuardRejection): string {
  return JSON.stringify({ error });
}
