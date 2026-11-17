# LingoSlate Soniox Key Broker

This self-hosted Cloudflare Worker exchanges a private broker token for a restricted Soniox temporary API key. The permanent Soniox key remains in Worker secrets and is never embedded in the iPhone app.

The issued key:

- opens only `transcribe_websocket` sessions;
- must be used within 60 seconds;
- can open one stream; and
- limits that stream to four hours.

## Requirements

- Node.js 22 or later.
- Cloudflare account.
- Soniox account and permanent API key.

## Test

```bash
npm ci
npm test
```

## Deploy

```bash
cp .dev.vars.example .dev.vars
openssl rand -hex 32
```

Edit `.dev.vars` with your own values:

```dotenv
SONIOX_API_KEY=your-permanent-soniox-key
LINGOSLATE_CLIENT_TOKEN=your-random-broker-token
```

Then authenticate and deploy:

```bash
npx wrangler login
npx wrangler deploy --secrets-file .dev.vars
```

Verify:

```bash
curl https://your-worker.workers.dev/health
```

Configure the iPhone app with:

- Service URL: `https://your-worker.workers.dev/v1/soniox/temporary-key`
- Broker token: the same `LINGOSLATE_CLIENT_TOKEN` deployed to the Worker

## Security Boundary

This bearer-token design is suitable only for personal or small trusted deployments. It is not a complete authentication or abuse-prevention system.

Before operating a public hosted service, add authenticated users, Apple App Attest, per-user rate limits and spending quotas, monitoring, revocation, and an incident-response process. Never commit `.dev.vars`, a permanent Soniox key, or a real broker token.

See the repository [Deployment Guide](../../docs/DEPLOYMENT.md) and [Security Policy](../../SECURITY.md).
