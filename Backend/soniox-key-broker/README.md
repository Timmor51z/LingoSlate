# LingoSlate Soniox key broker

This Cloudflare Worker exchanges a private broker token for a restricted Soniox
temporary API key. The permanent Soniox key exists only as a Worker secret.

The issued key:

- opens only `transcribe_websocket` sessions;
- must be used within 60 seconds;
- can open one stream;
- limits that stream to four hours; and
- is tagged as `lingoslate-ios-personal` in Soniox usage logs.

## Test

```bash
npm test
```

## Deploy

Install or run Wrangler through `npx`, authenticate, then create an ignored
`.dev.vars` file from `.dev.vars.example`:

```bash
npx wrangler login
openssl rand -hex 32
npx wrangler deploy --secrets-file .dev.vars
```

The iPhone settings use:

- Service URL: `https://<worker>.workers.dev/v1/soniox/temporary-key`
- Broker token: the same `LINGOSLATE_CLIENT_TOKEN` stored in `.dev.vars`

The bearer token is sufficient only for a private MVP. Before distributing the
app, replace it with authenticated users, App Attest validation, and per-user
rate/cost limits.
