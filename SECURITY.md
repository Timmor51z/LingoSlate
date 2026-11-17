# Security Policy

## Reporting a Vulnerability

Please report security issues privately through GitHub Security Advisories for this repository. Do not open a public issue containing API keys, broker tokens, private endpoints, recordings, transcripts, or exploit details.

Include:

- the affected commit or version;
- the platform and OS version;
- reproduction steps;
- expected and actual behavior; and
- the smallest non-sensitive logs needed to understand the issue.

## Credential Model

- The macOS Soniox API key is stored in macOS Keychain.
- The iPhone broker token is stored in iOS Keychain.
- The permanent Soniox key for iPhone belongs only in Cloudflare Worker secrets.
- Session files must not contain API keys or broker tokens.
- `.dev.vars`, `.env*`, `.broker-token`, recordings, exports, and private benchmark data are Git-ignored.

If a credential is exposed, revoke or rotate it immediately. Removing it from the latest commit is not sufficient because Git history, forks, logs, screenshots, and caches may retain it.

## Broker Scope

The included Worker creates restricted, single-use Soniox keys. Its shared bearer token is a private-MVP mechanism, not complete public authentication.

Anyone operating a public hosted broker must add authenticated users, Apple App Attest, rate limits, cost quotas, monitoring, revocation, and abuse response. Deployers are responsible for Soniox usage charges generated through their credentials.

## Data Handling

Local macOS modes process lecture audio on the Mac after model download. Soniox mode and the iPhone app send live audio and prepared context to Soniox. Recordings and session documents are saved locally by default.

Do not submit real classroom recordings or transcripts in bug reports unless every participant has consented and the data has been minimized.

## Supported Versions

Security fixes are applied to the current default branch. This development-preview project does not yet maintain parallel stable release branches.
