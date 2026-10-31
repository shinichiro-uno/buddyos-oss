/// cron のスケジュール解釈（mac-bridge の BridgeCronSchedule / CronExpression と同じ意味）。
/// 受け付ける形は 2 つ:
///   - 間隔: "30m" / "every 2h" / "90s" / "1d"（最短 60 秒）
///   - 5 フィールドの cron 式: "分 時 日 月 曜日"（曜日の 7 は日曜=0 に寄せる）
/// 時刻はすべてこの PC のローカル時刻で数える。

export type BridgeCronSchedule = { kind: "interval"; seconds: number } | { kind: "cron"; expr: CronExpression };

export interface CronExpression {
  minutes: Set<number>;
  hours: Set<number>;
  days: Set<number>;
  months: Set<number>;
  weekdays: Set<number>;
  /** 日フィールドが "*" 以外。日と曜日の両方が制限されているときは「どちらかが合えば」実行（vixie cron と同じ）。 */
  dayRestricted: boolean;
  weekdayRestricted: boolean;
}

export function parseSchedule(raw: string): BridgeCronSchedule | undefined {
  const trimmed = raw.trim();
  if (!trimmed) return undefined;
  const seconds = parseInterval(trimmed);
  if (seconds !== undefined) return { kind: "interval", seconds: Math.max(60, seconds) };
  const expr = parseCronExpression(trimmed);
  return expr ? { kind: "cron", expr } : undefined;
}

function parseInterval(raw: string): number | undefined {
  let s = raw.toLowerCase();
  if (s.startsWith("every ")) s = s.slice("every ".length);
  s = s.replace(/\s+/g, "");
  const unit = s.slice(-1);
  const mult = unit === "s" ? 1 : unit === "m" ? 60 : unit === "h" ? 3600 : unit === "d" ? 86400 : 0;
  if (!mult) return undefined;
  const body = s.slice(0, -1);
  if (!/^\d+$/.test(body)) return undefined;
  const n = Number.parseInt(body, 10);
  return n > 0 ? n * mult : undefined;
}

export function parseCronExpression(raw: string): CronExpression | undefined {
  const fields = raw.trim().split(/\s+/);
  if (fields.length !== 5) return undefined;
  const minutes = parseField(fields[0], 0, 59);
  const hours = parseField(fields[1], 0, 23);
  const days = parseField(fields[2], 1, 31);
  const months = parseField(fields[3], 1, 12);
  const weekdaysRaw = parseField(fields[4], 0, 7);
  if (!minutes || !hours || !days || !months || !weekdaysRaw) return undefined;
  const weekdays = new Set([...weekdaysRaw].map((d) => (d === 7 ? 0 : d)));
  return { minutes, hours, days, months, weekdays, dayRestricted: fields[2] !== "*", weekdayRestricted: fields[4] !== "*" };
}

function parseField(field: string, min: number, max: number): Set<number> | undefined {
  const out = new Set<number>();
  for (const part of field.split(",")) {
    if (!part) return undefined;
    const [rangePart, stepPart, extra] = part.split("/");
    if (extra !== undefined) return undefined;
    let step = 1;
    if (stepPart !== undefined) {
      if (!/^\d+$/.test(stepPart)) return undefined;
      step = Number.parseInt(stepPart, 10);
      if (step <= 0) return undefined;
    }
    let lo: number;
    let hi: number;
    if (rangePart === "*") {
      lo = min;
      hi = max;
    } else if (/^\d+-\d+$/.test(rangePart)) {
      const [a, b] = rangePart.split("-").map((v) => Number.parseInt(v, 10));
      lo = a;
      hi = b;
    } else if (/^\d+$/.test(rangePart)) {
      lo = Number.parseInt(rangePart, 10);
      // "N/s" は N から最大値まで s 刻み（vixie 互換）。
      hi = stepPart !== undefined ? max : lo;
    } else {
      return undefined;
    }
    if (lo < min || hi > max || lo > hi) return undefined;
    for (let v = lo; v <= hi; v += step) out.add(v);
  }
  return out;
}

function dayMatches(expr: CronExpression, date: Date): boolean {
  const dom = expr.days.has(date.getDate());
  const dow = expr.weekdays.has(date.getDay());
  if (expr.dayRestricted && expr.weekdayRestricted) return dom || dow;
  return dom && dow;
}

/** after より厳密に後の最初の発火時刻（秒は 0）。366 日先まで見つからなければ undefined。 */
export function nextCronFire(expr: CronExpression, after: Date): Date | undefined {
  const start = new Date(after.getTime() + 60_000);
  const day = new Date(start.getFullYear(), start.getMonth(), start.getDate());
  for (let i = 0; i <= 366; i += 1) {
    const d = new Date(day.getFullYear(), day.getMonth(), day.getDate() + i);
    if (expr.months.has(d.getMonth() + 1) && dayMatches(expr, d)) {
      for (let h = 0; h < 24; h += 1) {
        if (!expr.hours.has(h)) continue;
        for (let m = 0; m < 60; m += 1) {
          if (!expr.minutes.has(m)) continue;
          const candidate = new Date(d.getFullYear(), d.getMonth(), d.getDate(), h, m, 0, 0);
          if (candidate.getTime() > after.getTime()) return candidate;
        }
      }
    }
  }
  return undefined;
}

export function nextScheduleFire(schedule: BridgeCronSchedule, after: Date): Date | undefined {
  if (schedule.kind === "interval") return new Date(after.getTime() + schedule.seconds * 1000);
  return nextCronFire(schedule.expr, after);
}

/** ジョブ id ごとに決まる 0〜90 秒のずらし（同時刻のジョブが一斉に動かないように。mac と同じ FNV-1a 64）。 */
export function cronJitterSeconds(jobId: string, schedule: BridgeCronSchedule): number {
  let hash = 14695981039346656037n;
  for (const byte of Buffer.from(jobId, "utf8")) {
    hash ^= BigInt(byte);
    hash = (hash * 1099511628211n) & 0xffffffffffffffffn;
  }
  const cap = schedule.kind === "interval" ? Math.min(90, Math.max(0, Math.floor(schedule.seconds / 10))) : 90;
  if (cap < 1) return 0;
  return Number(hash % BigInt(cap));
}

const pad = (n: number): string => String(n).padStart(2, "0");

/** ローカル時刻の "yyyy-MM-dd HH:mm:ss"（一覧の nextRunAt / lastRunAt 用）。 */
export function formatLocalDateTime(d: Date): string {
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}

/** ローカル時刻の "yyyy-MM-dd_HH-mm-ss"（出力ファイル名。文字列の並びが時刻順になる）。 */
export function formatOutputStamp(d: Date): string {
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}_${pad(d.getHours())}-${pad(d.getMinutes())}-${pad(d.getSeconds())}`;
}

/** 出力ファイル名の時刻を読む（"yyyy-MM-dd_HH-mm-ss" か "yyyyMMdd_HHmmss"、ローカル時刻）。 */
export function parseOutputStamp(stem: string): Date | undefined {
  const m = /^(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})$/.exec(stem) ?? /^(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})$/.exec(stem);
  if (!m) return undefined;
  const [, y, mo, d, h, mi, s] = m.map((v) => Number.parseInt(v, 10));
  return new Date(y, mo - 1, d, h, mi, s);
}
