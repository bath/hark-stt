# api.hark.works

The website's live demo (issue #25): the Vercel project `hark-demo-api`
(team bath1s-projects) with the domain `api.hark.works`.

- `GET /api/transcribe` → `{"enabled": true|false}`. The site plays the
  simulated dictation when the demo is off.
- `POST /api/transcribe` with a 16 kHz mono 16-bit WAV of at most 15 s →
  `{"text", "server_ms", "audio_seconds"}`. Only `https://hark.works` may call
  it (CORS and an Origin check). Nothing is stored or logged.

Limits (`lib/limits.js`, tested with `npm test`): 20 clips per IP address per
hour, and 6 billed hours per day for everyone: about $0.24 a day at Groq's
$0.04 per hour. Groq bills each request as at least 10 s, so short clips
count as 10 s.

## Turn it on

The demo stays off until it has a Groq key and Redis for the counters:

1. Make a key at https://console.groq.com/keys, then
   `vercel env add GROQ_API_KEY production --scope bath1s-projects` (from this folder).
2. Add Upstash Redis from the Vercel Marketplace to the `hark-demo-api` project
   (it sets `KV_REST_API_URL` and `KV_REST_API_TOKEN`), or set
   `UPSTASH_REDIS_REST_URL` and `UPSTASH_REDIS_REST_TOKEN` yourself.
3. `vercel deploy --prod --scope bath1s-projects`, then
   `curl https://api.hark.works/api/transcribe` must say `"enabled":true`.
