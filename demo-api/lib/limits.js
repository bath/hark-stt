// The rules for the website's live demo (issue #25), apart from any server,
// so they can be tested. The demo sends a short clip to Groq's
// whisper-large-v3-turbo; nothing is stored.

export const ORIGIN = 'https://hark.works';
/** Longest clip, in seconds. The site stops at 15 s; this leaves room for the header. */
export const MAX_SECONDS = 16;
/** Clips per IP address per hour. */
export const PER_IP_PER_HOUR = 20;
/** Billed seconds for everyone per day: 6 hours, about $0.24 at Groq's $0.04 per hour. */
export const DAILY_SECONDS = 6 * 3600;
/** Groq bills each request as at least 10 s of audio. */
export const BILLED_MINIMUM = 10;

/**
 * Reads a 16-bit PCM WAV header and returns the clip length in seconds, or
 * null when the bytes are not a WAV this demo accepts.
 * @param {Uint8Array} bytes
 */
export function wavSeconds(bytes) {
  if (bytes.length < 44) return null;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const text = (at) => String.fromCharCode(...bytes.subarray(at, at + 4));
  if (text(0) !== 'RIFF' || text(8) !== 'WAVE') return null;
  let offset = 12, rate = 0, channels = 0, bits = 0;
  while (offset + 8 <= bytes.length) {
    const id = text(offset), size = view.getUint32(offset + 4, true);
    if (id === 'fmt ') {
      if (view.getUint16(offset + 8, true) !== 1) return null; // PCM only
      channels = view.getUint16(offset + 10, true);
      rate = view.getUint32(offset + 12, true);
      bits = view.getUint16(offset + 22, true);
    } else if (id === 'data') {
      if (!rate || !channels || bits !== 16) return null;
      const data = Math.min(size, bytes.length - offset - 8);
      return data / (rate * channels * 2);
    }
    offset += 8 + size + (size & 1);
  }
  return null;
}

/**
 * Decides whether a clip may go to Groq. `store` counts with expiry:
 * `incr(key, by, ttlSeconds)` returns the new total.
 * @returns {Promise<{ok: true} | {ok: false, status: number, error: string}>}
 */
export async function admit({ origin, ip, seconds, store, now = Date.now() }) {
  if (origin !== ORIGIN) return { ok: false, status: 403, error: 'origin' };
  if (seconds === null) return { ok: false, status: 415, error: 'not_wav' };
  if (seconds > MAX_SECONDS) return { ok: false, status: 413, error: 'too_long' };
  if (seconds < 0.3) return { ok: false, status: 400, error: 'too_short' };
  const hour = Math.floor(now / 3_600_000), day = Math.floor(now / 86_400_000);
  const clips = await store.incr(`ip:${ip}:${hour}`, 1, 3600);
  if (clips > PER_IP_PER_HOUR) return { ok: false, status: 429, error: 'rate_limited' };
  const used = await store.incr(`day:${day}`, Math.ceil(Math.max(seconds, BILLED_MINIMUM)), 86_400);
  if (used > DAILY_SECONDS) return { ok: false, status: 503, error: 'daily_cap' };
  return { ok: true };
}

/** A store on Upstash Redis's REST API (Vercel Marketplace sets these variables). */
export function redisStore(url, token) {
  return {
    async incr(key, by, ttl) {
      const response = await fetch(`${url}/pipeline`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify([['INCRBY', `hark-demo:${key}`, by], ['EXPIRE', `hark-demo:${key}`, ttl, 'NX']]),
      });
      if (!response.ok) throw new Error(`redis ${response.status}`);
      const [first] = await response.json();
      return Number(first.result);
    },
  };
}

/** A store in memory, for tests. */
export function memoryStore() {
  const counts = new Map();
  return { counts, async incr(key, by) { const total = (counts.get(key) || 0) + by; counts.set(key, total); return total; } };
}
