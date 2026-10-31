// Reference model of the Bridge-side LiveActivityRules (design scratch, NOT repo code).
// Pure state machine with an injected clock (seconds) and id generator, so Mac (Swift) and Windows (TS)
// can be tested against the same vectors (shared/fixtures/live-activity/publisher-cases.json).
//
// Inputs
//   counts(t, running)                      running = merged agents + workflows + bg sessions (no shells)
//   finished(t, {done, failed, stopped})    deltas of items that ended (agent rows, workflows, bg sessions)
//   register(t, {device, activityId, batch, shownRunning, shownFailed})   token arrived from the app
//   clear(t, {device, activityId})
//   tick(t)
// Outputs
//   pushes:  {t, device, activityId, event: "update"|"end", priority, state:{phase,running,failed}, staleAfterSec?, dismissAfterSec?}
//   states:  {t, rev, batch, phase, running, failed, since}   (background_work_state broadcast; debounce is the actor's job)

export const CFG = {
  END_GRACE: 20,
  MIN_INTERVAL: 10,
  KEEPALIVE: 600,
  STALE_AFTER: 1500,
  DISMISS_DONE: 300,
  DISMISS_FAILED: 900,
  ENDED_MEMORY: 900,
};

export class Rules {
  constructor(ids = ["b1", "b2", "b3", "b4"]) {
    this.ids = [...ids];
    this.batch = null; // {id, since, running, done, failed, stopped, endAt}
    this.lastEnded = null; // {id, since, phase, failed, at}
    this.targets = new Map(); // key -> {device, activityId, batch, shown:{running,failed}|null, lastPushAt, registeredAt}
    this.rev = 0;
    this.pushes = [];
    this.states = [];
  }

  key(d, a) { return `${d}|${a}`; }

  publish(t) {
    this.rev += 1;
    const b = this.batch;
    if (b) {
      this.states.push({ t, rev: this.rev, batch: b.id, phase: "running", running: b.running, failed: b.failed, since: b.since });
    } else if (this.lastEnded) {
      const e = this.lastEnded;
      this.states.push({ t, rev: this.rev, batch: e.id, phase: e.phase, running: 0, failed: e.failed, since: e.since });
    } else {
      this.states.push({ t, rev: this.rev, batch: null, phase: "idle", running: 0, failed: 0, since: null });
    }
  }

  counts(t, running) {
    const b = this.batch;
    if (!b) {
      if (running <= 0) return this.tick(t);
      this.batch = { id: this.ids.shift(), since: t, running, done: 0, failed: 0, stopped: 0, endAt: null };
      this.lastEnded = null;
      this.publish(t);
      return this.tick(t);
    }
    if (b.running !== running) {
      b.running = running;
      if (running > 0) b.endAt = null;
      else if (b.endAt === null) b.endAt = t + CFG.END_GRACE;
      this.publish(t);
    }
    this.tick(t);
  }

  finished(t, d) {
    const b = this.batch;
    if (!b) return this.tick(t);
    b.done += d.done ?? 0;
    const f = d.failed ?? 0;
    b.failed += f;
    b.stopped += d.stopped ?? 0;
    if (f > 0) this.publish(t);
    this.tick(t);
  }

  register(t, r) {
    const k = this.key(r.device, r.activityId);
    const known = (this.batch && r.batch === this.batch.id) || (this.lastEnded && r.batch === this.lastEnded.id);
    if (!known) return this.tick(t); // unknown batch: ignore (the app ends that activity itself)
    const prev = this.targets.get(k);
    this.targets.set(k, {
      device: r.device, activityId: r.activityId, batch: r.batch,
      shown: prev?.shown ?? { running: r.shownRunning, failed: r.shownFailed },
      lastPushAt: prev?.lastPushAt ?? null,
      registeredAt: t,
    });
    this.tick(t);
  }

  clear(t, r) {
    this.targets.delete(this.key(r.device, r.activityId));
    this.tick(t);
  }

  emit(t, tg, event, state, extra) {
    this.pushes.push({ t, device: tg.device, activityId: tg.activityId, event, priority: event === "end" ? 10 : 5, state, ...extra });
    tg.shown = { running: state.running, failed: state.failed };
    tg.lastPushAt = t;
  }

  tick(t) {
    const b = this.batch;
    // end
    if (b && b.running === 0 && b.endAt !== null && t >= b.endAt) {
      const phase = b.failed > 0 ? "failed" : b.stopped > 0 && b.done === 0 ? "stopped" : "done";
      this.lastEnded = { id: b.id, since: b.since, phase, failed: b.failed, at: t };
      this.batch = null;
      this.publish(t);
    }
    // late or pending ends
    const e = this.lastEnded;
    if (e) {
      for (const [k, tg] of this.targets) {
        if (tg.batch !== e.id) continue;
        const state = { phase: e.phase, running: 0, failed: e.failed };
        this.emit(t, tg, "end", state, { dismissAfterSec: e.phase === "failed" ? CFG.DISMISS_FAILED : CFG.DISMISS_DONE });
        this.targets.delete(k);
      }
      if (t - e.at >= CFG.ENDED_MEMORY && !this.batch) {
        this.lastEnded = null;
        this.publish(t);
      }
    }
    // updates
    const cur = this.batch;
    if (cur && cur.running > 0) {
      for (const tg of this.targets.values()) {
        if (tg.batch !== cur.id) continue;
        const want = { phase: "running", running: cur.running, failed: cur.failed };
        const since = tg.lastPushAt;
        if (tg.shown === null || tg.shown.running !== want.running) {
          if (since === null || t - since >= CFG.MIN_INTERVAL) this.emit(t, tg, "update", want, { staleAfterSec: CFG.STALE_AFTER });
        } else {
          const base = since ?? tg.registeredAt;
          if (t - base >= CFG.KEEPALIVE) this.emit(t, tg, "update", want, { staleAfterSec: CFG.STALE_AFTER, keepalive: true });
        }
      }
    }
    // drop targets of unknown batches
    for (const [k, tg] of this.targets) {
      const ok = (this.batch && tg.batch === this.batch.id) || (this.lastEnded && tg.batch === this.lastEnded.id);
      if (!ok) this.targets.delete(k);
    }
  }
}
