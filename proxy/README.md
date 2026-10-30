# t.hark.works

A reverse proxy for PostHog, so ad blockers that block `*.posthog.com` do not
drop hark.works analytics (issue #28). It is the Vercel project `hark-proxy`
(team bath1s-projects) with the domain `t.hark.works`. Vercel's DNS for
hark.works already points subdomains at Vercel.

`/static/*` and `/array/*` go to PostHog's asset host; everything else goes to
`us.i.posthog.com`. `docs/analytics.js` loads the library and sends events
through it.

Deploy a change:

```sh
cd proxy && vercel deploy --prod --scope bath1s-projects
```
