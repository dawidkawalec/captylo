/**
 * An in-memory sliding-window limiter: at most `limit` recorded hits per key in any
 * `windowMs`. Only allowed hits are recorded, so hammering a refused key does not push its
 * lockout further. One process, no persistence: a restart forgets every window (fine for a
 * single instance, see the plan's "Not in M4").
 */
export class RateLimiter {
  private readonly hits = new Map<string, number[]>();

  constructor(
    private readonly limit: number,
    private readonly windowMs: number,
    /** Above this many keys, a new key first sweeps the expired ones. */
    private readonly softMaxKeys = 10_000,
  ) {}

  /** Number of keys held right now (for tests). */
  get size(): number {
    return this.hits.size;
  }

  /** Whether one more hit for `key` at `now` fits the window. Records nothing. */
  allows(key: string, now: Date): boolean {
    return this.live(key, now.getTime()).length < this.limit;
  }

  /** Records a hit for `key` at `now`, whether or not it fits. */
  record(key: string, now: Date): void {
    const t = now.getTime();
    const live = this.live(key, t);
    if (live.length === 0 && !this.hits.has(key) && this.hits.size >= this.softMaxKeys) this.sweep(t);
    live.push(t);
    this.hits.set(key, live);
  }

  /** `allows` then `record` when allowed. */
  take(key: string, now: Date): boolean {
    if (!this.allows(key, now)) return false;
    this.record(key, now);
    return true;
  }

  /** The hits of `key` still inside the window ending at `t`; drops the key when none are. */
  private live(key: string, t: number): number[] {
    const list = this.hits.get(key);
    if (!list) return [];
    const from = t - this.windowMs;
    let first = 0;
    while (first < list.length && list[first]! <= from) first++;
    if (first === list.length) {
      this.hits.delete(key);
      return [];
    }
    if (first > 0) list.splice(0, first);
    return list;
  }

  private sweep(t: number): void {
    for (const key of [...this.hits.keys()]) this.live(key, t);
  }
}
