// POST /api/transcribe: the website's live demo (issue #25). The site sends a
// 16 kHz mono WAV of at most 15 s; this sends it to Groq's
// whisper-large-v3-turbo, the model the app runs on the Mac, and returns the
// text and the server time. Nothing is stored or logged.
// GET /api/transcribe tells the site whether the demo is on.
import { admit, redisStore, wavSeconds, ORIGIN, MAX_SECONDS } from '../lib/limits.js';

const env = process.env;
const redisURL = env.UPSTASH_REDIS_REST_URL || env.KV_REST_API_URL;
const redisToken = env.UPSTASH_REDIS_REST_TOKEN || env.KV_REST_API_TOKEN;
// Without a key or the counters for the limits, the demo stays off.
const enabled = Boolean(env.GROQ_API_KEY && redisURL && redisToken);

const cors = {
  'Access-Control-Allow-Origin': ORIGIN,
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
  'Access-Control-Max-Age': '86400',
  Vary: 'Origin',
};
const json = (body, status = 200) =>
  Response.json(body, { status, headers: { ...cors, 'Cache-Control': 'no-store' } });

export function OPTIONS() {
  return new Response(null, { status: 204, headers: cors });
}

export function GET() {
  return json({ enabled, max_seconds: MAX_SECONDS - 1 });
}

export async function POST(request) {
  if (!enabled) return json({ error: 'demo_off' }, 503);
  const body = new Uint8Array(await request.arrayBuffer());
  if (body.length > 1_000_000) return json({ error: 'too_long' }, 413);
  const seconds = wavSeconds(body);
  const ip = (request.headers.get('x-forwarded-for') || '').split(',')[0].trim() || 'unknown';
  const verdict = await admit({
    origin: request.headers.get('origin'), ip, seconds, store: redisStore(redisURL, redisToken),
  });
  if (!verdict.ok) return json({ error: verdict.error }, verdict.status);

  const form = new FormData();
  form.append('file', new Blob([body], { type: 'audio/wav' }), 'clip.wav');
  form.append('model', 'whisper-large-v3-turbo');
  form.append('language', 'en');
  form.append('response_format', 'json');
  form.append('temperature', '0');
  const started = performance.now();
  const groq = await fetch('https://api.groq.com/openai/v1/audio/transcriptions', {
    method: 'POST', headers: { Authorization: `Bearer ${env.GROQ_API_KEY}` }, body: form,
  });
  const serverMs = Math.round(performance.now() - started);
  if (!groq.ok) return json({ error: 'transcription_failed' }, 502);
  const { text } = await groq.json();
  return json({ text: (text || '').trim(), server_ms: serverMs, audio_seconds: Math.round(seconds * 10) / 10 });
}
