/// iPhone ↔ Bridge の通信量の計測（mac の TrafficMeter と同じ）。持つのはバケットごとの件数とバイト数だけで、
/// 中身（本文・ファイル名・URL・鍵・端末トークン）は一切残さない。GET /traffic・POST /traffic/reset で読む。

interface Bucket {
  messages: number;
  bytes: number;
}

class TrafficMeter {
  private startedAt = Date.now();
  private buckets = new Map<string, Bucket>();

  record(bucket: string, bytes: number, messages = 1): void {
    if (bytes < 0 || messages < 0) return;
    const b = this.buckets.get(bucket) ?? { messages: 0, bytes: 0 };
    b.messages += messages;
    b.bytes += bytes;
    this.buckets.set(bucket, b);
  }

  snapshot(): Record<string, unknown> {
    let totalMessages = 0;
    let totalBytes = 0;
    for (const b of this.buckets.values()) {
      totalMessages += b.messages;
      totalBytes += b.bytes;
    }
    return {
      startedAt: new Date(this.startedAt).toISOString().replace(/\.\d{3}Z$/, "Z"),
      elapsedSeconds: Math.max(0, (Date.now() - this.startedAt) / 1000),
      totalMessages,
      totalBytes,
      buckets: Object.fromEntries(this.buckets)
    };
  }

  reset(): Record<string, unknown> {
    this.startedAt = Date.now();
    this.buckets.clear();
    return this.snapshot();
  }
}

export const trafficMeter = new TrafficMeter();
