import { test } from 'node:test';
import assert from 'node:assert/strict';
import { admit, memoryStore, wavSeconds, PER_IP_PER_HOUR, DAILY_SECONDS, ORIGIN } from '../lib/limits.js';

/** A 16 kHz mono 16-bit WAV of `seconds` of silence. */
function wav(seconds, rate = 16000) {
  const data = Math.round(seconds * rate) * 2;
  const bytes = new Uint8Array(44 + data), view = new DataView(bytes.buffer);
  const put = (at, s) => [...s].forEach((c, i) => (bytes[at + i] = c.charCodeAt(0)));
  put(0, 'RIFF'); view.setUint32(4, 36 + data, true); put(8, 'WAVE');
  put(12, 'fmt '); view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true);
  view.setUint32(24, rate, true); view.setUint32(28, rate * 2, true); view.setUint16(32, 2, true); view.setUint16(34, 16, true);
  put(36, 'data'); view.setUint32(40, data, true);
  return bytes;
}

const ok = { origin: ORIGIN, ip: '1.2.3.4' };

test('reads the length of a WAV', () => {
  assert.equal(wavSeconds(wav(3)), 3);
  assert.equal(wavSeconds(wav(2, 48000)), 2);
  assert.equal(wavSeconds(new TextEncoder().encode('not a wav, just some text that is long enough.')), null);
});

test('only hark.works may use the demo', async () => {
  const verdict = await admit({ ...ok, origin: 'https://example.com', seconds: 3, store: memoryStore() });
  assert.deepEqual(verdict, { ok: false, status: 403, error: 'origin' });
});

test('clips must be WAV and at most 16 s', async () => {
  const store = memoryStore();
  assert.equal((await admit({ ...ok, seconds: null, store })).error, 'not_wav');
  assert.equal((await admit({ ...ok, seconds: 30, store })).error, 'too_long');
  assert.equal((await admit({ ...ok, seconds: 0.1, store })).error, 'too_short');
  assert.equal((await admit({ ...ok, seconds: 15, store })).ok, true);
});

test('each IP address gets a set number of clips per hour', async () => {
  const store = memoryStore(), now = Date.UTC(2026, 9, 30, 12);
  for (let i = 0; i < PER_IP_PER_HOUR; i++) assert.equal((await admit({ ...ok, seconds: 3, store, now })).ok, true);
  assert.deepEqual(await admit({ ...ok, seconds: 3, store, now }), { ok: false, status: 429, error: 'rate_limited' });
  // Another address, or the next hour, is fine.
  assert.equal((await admit({ ...ok, ip: '5.6.7.8', seconds: 3, store, now })).ok, true);
  assert.equal((await admit({ ...ok, seconds: 3, store, now: now + 3_600_000 })).ok, true);
});

test('short clips count as the 10 s Groq bills', async () => {
  const store = memoryStore(), now = Date.UTC(2026, 9, 30, 12);
  await admit({ ...ok, seconds: 2, store, now });
  assert.equal(store.counts.get(`day:${Math.floor(now / 86_400_000)}`), 10);
});

test('the daily cap stops the demo for everyone', async () => {
  const store = memoryStore(), now = Date.UTC(2026, 9, 30, 12);
  store.counts.set(`day:${Math.floor(now / 86_400_000)}`, DAILY_SECONDS - 2);
  assert.deepEqual(await admit({ ...ok, seconds: 5, store, now }), { ok: false, status: 503, error: 'daily_cap' });
  assert.equal((await admit({ ...ok, seconds: 5, store, now: now + 86_400_000 })).ok, true);
});
