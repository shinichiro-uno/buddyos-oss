import { execFile } from "node:child_process";
import fs from "node:fs";
import type http from "node:http";
import os from "node:os";
import path from "node:path";
import { trafficMeter } from "./trafficMeter.js";

/// Live Preview の端末画面（mac の SimController / SimFramebuffer に当たるもの）を Android で出す。
/// iOS Simulator は Windows では動かないので、adb でつながった Android のエミュレータ・実機を
/// 同じ /preview/sim/* の口（stream / frame / tap / swipe / home / text）で見せて操作させる。
///   - 一覧: `adb devices -l`（/preview/targets の sim に platform:"android" を付けて並べる）
///   - 画面: `adb exec-out screencap -p`（PNG。multipart/x-mixed-replace で流す。1〜3 fps 程度）
///   - 操作: `adb shell input tap / swipe / keyevent KEYCODE_HOME / text`
/// iOS アプリは sim の各項目を読むだけなので、知らない platform は無視して今のまま表示・操作できる。

const ADB_TIMEOUT_MS = 10_000;
/** 1 枚取ったら次を取るまでの最短の間隔。中継の量を抑える。 */
const FRAME_INTERVAL_MS = 350;
/** この秒数 write が無ければ直前フレームを再送して切断を検知する（mac と同じ）。 */
const KEEPALIVE_MS = 5_000;
/** 一度もフレームが取れないままこの秒数経ったらストリームを閉じる（mac と同じ）。 */
const NO_FRAME_TIMEOUT_MS = 20_000;

export interface AdbDevice {
  serial: string;
  state: string;
  model?: string;
}

/** `adb devices -l` の出力。「device」状態（使える）以外も state を付けて返す。 */
export function parseAdbDevices(stdout: string): AdbDevice[] {
  const out: AdbDevice[] = [];
  for (const line of stdout.split(/\r?\n/)) {
    const t = line.trim();
    if (!t || t.startsWith("List of devices") || t.startsWith("*")) continue;
    const parts = t.split(/\s+/);
    if (parts.length < 2) continue;
    const model = /\bmodel:(\S+)/.exec(t)?.[1]?.replace(/_/g, " ");
    out.push({ serial: parts[0], state: parts[1], ...(model ? { model } : {}) });
  }
  return out;
}

/** `adb shell wm size`。Override（表示を変えている）があればそちら。 */
export function parseWmSize(stdout: string): { w: number; h: number } | undefined {
  const pick = (label: string): { w: number; h: number } | undefined => {
    const m = new RegExp(`${label} size:\\s*(\\d+)x(\\d+)`).exec(stdout);
    return m ? { w: Number.parseInt(m[1], 10), h: Number.parseInt(m[2], 10) } : undefined;
  };
  return pick("Override") ?? pick("Physical");
}

/** PNG の IHDR から幅と高さ（いまの向きの画面の大きさ。タップ座標の換算に使う）。 */
export function pngSize(data: Buffer): { w: number; h: number } | undefined {
  if (data.length < 24 || data.readUInt32BE(0) !== 0x89504e47 || data.toString("latin1", 12, 16) !== "IHDR") return undefined;
  return { w: data.readUInt32BE(16), h: data.readUInt32BE(20) };
}

/**
 * `adb shell input text` に渡す 1 つの引数。空白は %s（input text の決まり）にし、
 * 端末側の sh が解釈しないよう単一引用符で包む。input text は ASCII しか打てない。
 */
export function adbInputTextArg(text: string): string {
  const s = text.replace(/ /g, "%s");
  return `'${s.replace(/'/g, "'\\''")}'`;
}

/** adb の場所。ANDROID_ADB → Android SDK（ANDROID_HOME / ANDROID_SDK_ROOT / %LOCALAPPDATA%\Android\Sdk）→ PATH。 */
export function adbPath(env: NodeJS.ProcessEnv = process.env): string {
  const exe = process.platform === "win32" ? "adb.exe" : "adb";
  if (env.ANDROID_ADB && fs.existsSync(env.ANDROID_ADB)) return env.ANDROID_ADB;
  const sdks = [env.ANDROID_HOME, env.ANDROID_SDK_ROOT];
  if (process.platform === "win32") sdks.push(path.join(env.LOCALAPPDATA ?? path.join(os.homedir(), "AppData", "Local"), "Android", "Sdk"));
  else sdks.push(path.join(os.homedir(), "Library", "Android", "sdk"), path.join(os.homedir(), "Android", "Sdk"));
  for (const sdk of sdks) {
    if (!sdk) continue;
    const p = path.join(sdk, "platform-tools", exe);
    if (fs.existsSync(p)) return p;
  }
  return "adb";
}

function adb(args: string[]): Promise<{ ok: boolean; out: Buffer; err: string }> {
  return new Promise((resolve) => {
    execFile(
      adbPath(),
      args,
      { timeout: ADB_TIMEOUT_MS, windowsHide: true, encoding: "buffer", maxBuffer: 64 * 1024 * 1024 },
      (error, stdout, stderr) => {
        const err = (stderr?.toString("utf8") ?? "").trim() || (error ? error.message : "");
        resolve({ ok: !error, out: stdout ?? Buffer.alloc(0), err });
      }
    );
  });
}

export interface AndroidSimTarget {
  udid: string;
  name: string;
  state: string;
  wPts: number;
  hPts: number;
  platform: "android";
}

const sizeCache = new Map<string, { w: number; h: number }>();

async function screenSize(serial: string): Promise<{ w: number; h: number }> {
  const hit = sizeCache.get(serial);
  if (hit) return hit;
  const r = await adb(["-s", serial, "shell", "wm", "size"]);
  const size = (r.ok && parseWmSize(r.out.toString("utf8"))) || { w: 0, h: 0 };
  if (size.w > 0) sizeCache.set(serial, size);
  return size;
}

/** 画面の縦横比（/preview/ui のタップ座標の fallback 用。分からなければ 0）。 */
export async function androidAspect(serial: string): Promise<number> {
  const { w, h } = await pixelSize(serial);
  return w > 0 && h > 0 ? w / h : 0;
}

/** /preview/targets の sim。adb が無い・端末が無いときは空。 */
export async function androidTargets(): Promise<AndroidSimTarget[]> {
  const r = await adb(["devices", "-l"]);
  if (!r.ok) return [];
  const devices = parseAdbDevices(r.out.toString("utf8")).filter((d) => d.state === "device");
  return Promise.all(
    devices.map(async (d) => {
      const size = await screenSize(d.serial);
      return {
        udid: d.serial,
        name: `${d.model ?? d.serial} (Android)`,
        state: "Booted",
        wPts: size.w,
        hPts: size.h,
        platform: "android" as const
      };
    })
  );
}

/** 端末ごとの取り込み。見ている人がいる間だけ screencap を回し、最新の 1 枚を持つ。 */
class FrameSource {
  latest?: Buffer;
  private readonly listeners = new Set<(frame: Buffer) => void>();
  private running = false;

  constructor(private readonly serial: string) {}

  subscribe(listener: (frame: Buffer) => void): () => void {
    this.listeners.add(listener);
    if (!this.running) void this.loop();
    return () => this.listeners.delete(listener);
  }

  async capture(): Promise<Buffer | undefined> {
    const r = await adb(["-s", this.serial, "exec-out", "screencap", "-p"]);
    if (!r.ok || !pngSize(r.out)) return undefined;
    this.latest = r.out;
    return r.out;
  }

  private async loop(): Promise<void> {
    this.running = true;
    try {
      while (this.listeners.size > 0) {
        const started = Date.now();
        const frame = await this.capture();
        if (frame) for (const l of [...this.listeners]) l(frame);
        const wait = frame ? Math.max(0, FRAME_INTERVAL_MS - (Date.now() - started)) : 1000;
        await new Promise((r) => setTimeout(r, wait));
      }
    } finally {
      this.running = false;
    }
  }
}

const sources = new Map<string, FrameSource>();
const sourceFor = (serial: string): FrameSource => {
  let s = sources.get(serial);
  if (!s) {
    s = new FrameSource(serial);
    sources.set(serial, s);
  }
  return s;
};

/** GET /preview/sim/stream。同じ画面が続く間は送らず、5 秒ごとに直前の 1 枚を送り直して切断を検知する。 */
export function streamAndroid(req: http.IncomingMessage, res: http.ServerResponse, serial: string): void {
  res.writeHead(200, {
    "content-type": "multipart/x-mixed-replace; boundary=frame",
    "cache-control": "no-store",
    connection: "close"
  });
  const startedAt = Date.now();
  let lastWriteAt = startedAt;
  let lastSent: Buffer | undefined;
  let closed = false;
  const write = (frame: Buffer): void => {
    if (closed) return;
    const header = `--frame\r\nContent-Type: image/png\r\nContent-Length: ${frame.length}\r\n\r\n`;
    trafficMeter.record("preview.sim.stream.out", Buffer.byteLength(header) + frame.length + 2);
    res.write(header);
    res.write(frame);
    res.write("\r\n");
    lastWriteAt = Date.now();
    lastSent = frame;
  };
  const unsubscribe = sourceFor(serial).subscribe((frame) => {
    if (lastSent && frame.equals(lastSent)) return;
    write(frame);
  });
  const finish = (): void => {
    if (closed) return;
    closed = true;
    clearInterval(ticker);
    unsubscribe();
    res.end();
  };
  const ticker = setInterval(() => {
    if (Date.now() - lastWriteAt < KEEPALIVE_MS) return;
    if (lastSent) write(lastSent);
    else if (Date.now() - startedAt >= NO_FRAME_TIMEOUT_MS) finish();
  }, 1000);
  req.on("close", finish);
  res.on("error", finish);
}

/** GET /preview/sim/frame（「画面をエージェントに送る」）。 */
export async function androidFrame(serial: string): Promise<Buffer | undefined> {
  const source = sourceFor(serial);
  return (await source.capture()) ?? source.latest;
}

const clamp01 = (v: number): number => (Number.isFinite(v) ? Math.min(1, Math.max(0, v)) : 0);

/** 0〜1 の座標を、いまの向きの画面のピクセルに直す。 */
async function pixelSize(serial: string): Promise<{ w: number; h: number }> {
  const latest = sources.get(serial)?.latest;
  return (latest && pngSize(latest)) || (await screenSize(serial));
}

export type ControlResult = { ok: boolean; body: string };

export async function androidControl(serial: string, action: string, q: URLSearchParams): Promise<ControlResult> {
  const num = (k: string, fallback = 0): number => {
    const v = Number.parseFloat(q.get(k) ?? "");
    return Number.isFinite(v) ? v : fallback;
  };
  let args: string[];
  let label = action;
  if (action === "tap") {
    const { w, h } = await pixelSize(serial);
    const x = Math.round(clamp01(num("x")) * w);
    const y = Math.round(clamp01(num("y")) * h);
    args = ["input", "tap", String(x), String(y)];
    label = `tap ${x},${y}`;
  } else if (action === "swipe") {
    const { w, h } = await pixelSize(serial);
    const d = Math.min(2, Math.max(0.05, num("d", 0.3)));
    const points = [clamp01(num("x1")) * w, clamp01(num("y1")) * h, clamp01(num("x2")) * w, clamp01(num("y2")) * h];
    args = ["input", "swipe", ...points.map((v) => String(Math.round(v))), String(Math.round(d * 1000))];
  } else if (action === "home") {
    args = ["input", "keyevent", "KEYCODE_HOME"];
  } else if (action === "text") {
    const text = q.get("q") ?? "";
    if (!text) return { ok: true, body: "text" };
    args = ["input", "text", adbInputTextArg(text)];
  } else {
    return { ok: false, body: "unknown action" };
  }
  const r = await adb(["-s", serial, "shell", ...args]);
  return r.ok ? { ok: true, body: label } : { ok: false, body: r.err || "adb failed" };
}

/** 単一引用符の JS 文字列に埋め込めるようにする（mac の jsString と同じ）。 */
function jsString(s: string): string {
  return s
    .replace(/\\/g, "\\\\")
    .replace(/'/g, "\\'")
    .replace(/\n/g, "\\n")
    .replace(/\r/g, "\\r")
    .replace(/</g, "\\u003C")
    .replace(/>/g, "\\u003E");
}

/** /preview/ui の端末画面ページ（mac の simPageHTML と同じ作り。ストリームとタップ・スワイプ）。 */
export function androidPageHTML(udid: string, aspect = 0): string {
  return `<!doctype html><html><head>
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
<meta name="referrer" content="no-referrer">
<title>BuddyOS Android</title>
<style>
*{box-sizing:border-box;-webkit-user-select:none;user-select:none;-webkit-tap-highlight-color:transparent}
html,body{margin:0;background:#000;height:100%;font-family:-apple-system,sans-serif;color:#ccc}
#wrap{height:100%;display:flex;flex-direction:column;align-items:center}
#stage{flex:1;display:flex;align-items:center;justify-content:center;width:100%;min-height:0}
img{max-width:100%;max-height:100%;object-fit:contain;touch-action:none}
#touch{position:fixed;left:0;top:0;width:40px;height:40px;margin:-20px 0 0 -20px;border-radius:50%;background:rgba(255,255,255,.28);border:1.5px solid rgba(255,255,255,.7);pointer-events:none;opacity:0;transition:opacity .18s}
</style></head>
<body><div id="wrap">
<div id="stage"><img id="v" alt="loading…"></div>
<div id="touch"></div>
</div>
<script>
const KEY=new URLSearchParams(location.search).get('apiKey')||'';
const UDID='${jsString(udid)}';
const AR_FALLBACK=${aspect > 0 && Number.isFinite(aspect) ? aspect : 0};
const qs=(extra)=>'?udid='+encodeURIComponent(UDID)+(KEY?'&apiKey='+encodeURIComponent(KEY):'')+(extra?'&'+extra:'');
const img=document.getElementById('v');
img.src='/preview/sim/stream'+qs();
let retry=0,retryTimer=null;
img.addEventListener('load',()=>{retry=0;});
img.addEventListener('error',()=>{
  if(retryTimer||retry>=10)return;
  const wait=Math.min(30000,1000*Math.pow(2,retry));retry++;
  retryTimer=setTimeout(()=>{retryTimer=null;img.src='/preview/sim/stream'+qs('_='+Date.now());},wait);
});
function imgAspect(r){
  if(img.naturalWidth>0&&img.naturalHeight>0)return img.naturalWidth/img.naturalHeight;
  if(AR_FALLBACK>0)return AR_FALLBACK;
  return r.width/r.height;
}
function norm(ev){const r=img.getBoundingClientRect();
  const ar=imgAspect(r), br=r.width/r.height;
  let dw=r.width,dh=r.height,ox=0,oy=0;
  if(br>ar){dw=r.height*ar;ox=(r.width-dw)/2;}else{dh=r.width/ar;oy=(r.height-dh)/2;}
  const x=(ev.clientX-r.left-ox)/dw, y=(ev.clientY-r.top-oy)/dh;
  return {x:Math.max(0,Math.min(1,x)),y:Math.max(0,Math.min(1,y))};}
const touch=document.getElementById('touch');
function showTouch(e){touch.style.transform='translate('+e.clientX+'px,'+e.clientY+'px)';touch.style.opacity='1';}
let down=null,t0=0;
img.addEventListener('pointerdown',e=>{down=norm(e);t0=Date.now();showTouch(e);try{img.setPointerCapture(e.pointerId);}catch(_){}});
img.addEventListener('pointermove',e=>{if(down)showTouch(e);});
img.addEventListener('pointercancel',()=>{down=null;touch.style.opacity='0';});
img.addEventListener('pointerup',e=>{touch.style.opacity='0';if(!down)return;const up=norm(e);
  const dx=Math.abs(up.x-down.x),dy=Math.abs(up.y-down.y);
  if(dx<0.02&&dy<0.02){fetch('/preview/sim/tap'+qs('x='+down.x+'&y='+down.y));}
  else{const dur=Math.min(1,(Date.now()-t0)/1000)||0.2;
    fetch('/preview/sim/swipe'+qs('x1='+down.x+'&y1='+down.y+'&x2='+up.x+'&y2='+up.y+'&d='+dur));}
  down=null;});
</script></body></html>`;
}
