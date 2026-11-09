# haraka-plugin-wildduck - AI Development Guide

> **Git policy — never auto-commit or auto-push.** Leave your work in the working tree.
> Run `git commit`, `git push`, `gh pr create`, or `scripts/push_all.sh` **only when the user
> explicitly asks in that turn**. Approval for an earlier change does not carry forward, and
> finishing a task is not permission to commit it.

## Overview

SMTP delivery plugin for Haraka that integrates with the WildDuck mail server. Handles the complete inbound email pipeline: SMTP negotiation, email authentication (SPF/DKIM/DMARC/ARC/BIMI), spam filtering via Rspamd, rate limiting, recipient validation, message forwarding, autoreply generation, and final storage into MongoDB. This is the sole delivery plugin needed -- do not enable Haraka's built-in SPF or dkim_verify plugins alongside it.

- **Package**: `@sudobility/haraka` (fork of upstream `haraka-plugin-wildduck`); see `package.json` for current version
- **License**: BUSL-1.1 (`LICENSE` is the full Business Source License text)
- **Runtime**: Node.js >= 16.20.1 (Haraka SMTP daemon)
- **Package Manager**: works with npm; `bun.lock` is the committed lockfile (no `package-lock.json`). `@sudobility/*` deps resolve from GitHub Packages via `.npmrc` and need a token with `read:packages`.
- **Language**: JavaScript (CommonJS, `require`/`exports`)
- **Repository**: https://github.com/Sudobility/haraka-plugin-wildduck

## Project Structure

Layout is documented in `README.md`. The code is small: `index.js` (~2000 lines)
holds every SMTP hook and the processing logic; `lib/` has `auth.js` (mailauth
checks), `db.js` (connections + handler init), `hooks.js` (thin wrappers),
`stream-collect.js` (chunk-buffering transform stream). `ARCHITECTURE.md` is the
deep-dive; this file is the quick reference.

## Key Components

### SMTP Hook Flow

```
MAIL FROM ──► hook_mail()
               ├── init_wildduck_transaction()  → txn.notes setup
               └── hookMail() (lib/hooks.js)    → SPF via mailauth → Received-SPF header

RCPT TO ───► hook_rcpt()
               ├── DB retry (up to 5 attempts, 8s timeout)
               └── real_rcpt_handler()
                    ├── normalize_address()      → SRS fix, punycode
                    ├── SRS handling              → Reverse SRS, rate check, forward
                    ├── resolveAddress()          → MongoDB user/forwarding lookup
                    ├── handle_forwarding_address() → Rate limit, forward targets
                    ├── User validation           → Exists? Enabled? Quota?
                    └── checkRateLimit()          → rcptIp + rcpt checks

DATA ──────► hook_data_post()
               └── hookDataPost() (lib/auth.js)
                    ├── DKIM verify → ARC validate → DMARC check → BIMI validate
                    └── Auth results headers + GELF logging

QUEUE ─────► hook_queue()
               ├── Rspamd blacklist/softlist     → Reject if matched
               ├── forwardMessage()              → Queue to ZoneMTA via Maildropper
               ├── sendAutoreplies()             → Time-window check, queue autoreply
               ├── storeMessages()               → FilterHandler.storeMessage() per user
               │    ├── BIMI logo fetch, filter rules, spam routing
               │    └── MongoDB + GridFS storage
               └── updateRateLimits()            → Increment Redis counters

DENY ──────► hook_deny()                         → GELF rejection logging
MAX DATA ──► hook_max_data_exceeded()            → GELF oversize denial
```

### Database Connections (lib/db.js)

`open_database` populates `plugin.db` with Mongo clients (`database`, `users`,
`gridfs`, `senderDb`), the `redis` client, and the WildDuck handlers
(`userHandler`, `messageHandler`, `settingsHandler`). Also set on `plugin`:
`ttlcounter`/`ttlcounterAsync`, `maildrop`, `filterHandler`, `bimiHandler`.

Connection retry: MongoDB reconnects every 2 seconds on failure. RCPT hook retries 5 times with 8s hard timeout.

### Rate Limiting

Redis TTL counters with check-before-increment pattern: check (increment=0) during RCPT, increment (increment=1) after delivery in QUEUE.

| Selector | Key Pattern | Default | Window | Purpose |
|----------|-------------|---------|--------|---------|
| `rcpt` | `rl:rcpt:{userId}` | 60 | 1 hour | Per-recipient |
| `rcptIp` | `rl:rcptIp:{ip}:{userId}` | 100 | 1 min | Per-IP per-recipient |
| `wdf` | `wdf:{addressId}` | configurable | 1 hour | Forward rate |

Keys accumulate in `txn.notes.rateKeys[]` and batch-update via `updateRateLimits()`.

### Transaction Context (txn.notes)

Cross-hook state lives on `txn.notes`, initialized in `init_wildduck_transaction()`:
`id`, `sender`, `transmissionType`, `rejectCode`; the auth results
(`spfResult`/`dkimResult`/`arcResult`/`dmarcResult`/`bimiResult`); `targets`
(Maps `users`, `forwards`, `autoreplies`, `forwardCounters` + a `recipients`
Set); `rateKeys[]` (`{selector,key,limit}` for post-delivery increment); and
`settings` (`const:max:storage`/`recipients`/`forwards`).

### Spam Filtering (Rspamd)

Reads `txn.results.get('rspamd')` from Haraka's Rspamd plugin:
- **Blacklist** (`rspamd.blacklist`): Hard reject (DENY/550). E.g., `DMARC_POLICY_REJECT`.
- **Softlist** (`rspamd.softlist`): Temp reject (DENYSOFT/450). E.g., `RBL_ZONE`.
- **Forward skip** (`rspamd.forwardSkip`): Suppress forwarding above this score.
- Custom rejection messages support `{host}` placeholder for sender domain.

### Forwarding and Autoreplies

Forwarding types: `mail` (email forward) and `relay` (specific MTA, not rate limited). Processing order in QUEUE: forward message -> send autoreplies -> store to inbox.

Stream piping: `txn.message_stream -> StreamCollect -> Maildropper`. StreamCollect buffers chunks for reuse by storeMessage() and autoreply().

Autoreply conditions: `autoreply.status` truthy, current time within start/end window, recipient in To:/Cc: headers.

## Development Commands

```bash
npm install              # Install deps (patch-package runs via postinstall)
npm run lint             # ESLint on index.js and lib/
npm run lint:fix         # Auto-fix ESLint issues
npm run test:unit        # Grunt default: ESLint + Mocha (44 tests). NOTE: there is NO `npm test` script
npx grunt test           # Mocha only (skip lint)
npm run update           # rm node_modules + package-lock.json, ncu -u, npm install
```

**Tests**: Mocha + Chai (`expect`) + Sinon. Files in `test/**/*.test.js`. Mock Haraka connection/transaction objects; no live DB needed. Runner is Grunt (`Gruntfile.js`): default task = eslint + mochaTest; `test` task = mochaTest only.

**ESLint**: ESLint 9 uses the flat config `eslint.config.js` (ES2022, CommonJS, Haraka globals `OK`/`DENY`/`DENYSOFT`/… declared there). The legacy `.eslintrc` is not used by ESLint 9.

**Code style**: Prettier (160 chars, 4-space, single quotes, LF, no trailing comma, avoid arrow parens).

**Docker**: Multi-stage build cloning Haraka v3.1.1 and copying this repo into its `node_modules`. Requires a `GH_PACKAGES_TOKEN` build arg (writes a temp `~/.npmrc`) to pull `@sudobility` packages from GitHub Packages.

**CI/CD**: `.github/workflows/ci-cd.yml` runs on push/PR to `main`/`develop`, delegating to the reusable `johnqh/workflows/.github/workflows/unified-cicd.yml@main` (`publish-target: github`, `docker-image-name: haraka`).

## Architecture Patterns

**Plugin convention**: `exports.hook_{name}` functions auto-discovered by Haraka. Only `init_master`/`init_child` are explicitly registered in `register()`.

**DSN responses**: Custom DSN creators at module level: `DSN.rcpt_too_fast()` (450), `DSN.mbox_full_554()` (554). Errors carry `.resolution` metadata for GELF and `.responseAction`/`.responseMessage` for hook responses.

**GELF logging**: `plugin.loggelf({short_message, _mail_action, _from, _to, _queue_id, ...})`. Component: `'mx'`. All underscore-prefixed custom fields.

**Stream once**: Message streams consumed once. StreamCollect buffers chunks for multi-use (forward + store + autoreply).

**SRS handling**: `^SRS\d+=` addresses reversed during RCPT TO, case-mangling fixed, forwarded to original address.

**Config reload**: `wildduck.yaml` auto-reloads via Haraka config watcher callback.

**WildDuck config disabled**: `process.env.DISABLE_WILD_CONFIG = 'true'` at module load prevents WildDuck from loading its own configs.

## Common Tasks (where to edit)

- **New auth check**: add to `lib/auth.js` (`hookMail` envelope / `hookDataPost` body); store on `txn.notes.{check}Result`; emit header via `connection.auth_results()`; log via `plugin.loggelf()`.
- **New SMTP hook**: add `exports.hook_{name}` in `index.js` (auto-discovered); init any state in `init_wildduck_transaction()`.
- **Rate limits**: edit `config/wildduck.yaml` `limits`; new dimension = a `checkRateLimit()` call in `real_rcpt_handler()` pushing to `txn.notes.rateKeys`.
- **Recipient handling**: `real_rcpt_handler()` in `index.js`, branching after the `resolveAddress()` callback; set `txn.notes.rejectCode` before rejecting.
- **Message storage**: `storeMessages()` inside `hook_queue()`; the `prepared` object (mimeTree + maildata) is reused across recipients.

## Error Codes

| Code | Meaning | Response |
|------|---------|----------|
| `NO_SUCH_USER` | Unknown recipient | DENY |
| `MBOX_DISABLED` | Account disabled | DENY |
| `MBOX_FULL` | Quota exceeded | DENY |
| `RATE_LIMIT` | Rate limit hit | DENYSOFT |
| `ERRC01` | RCPT handler error | DENYSOFT |
| `ERRC02` | DB not available | DENYSOFT |
| `ERRC03` | RCPT timeout (8s) | DENYSOFT |
| `ERRQ01` | Stream pipe failure | DENYSOFT |
| `ERRQ04` | Forward stream error | DENYSOFT |
| `ERRQ05` | Storage failure | DENYSOFT |
| `ERRQ06` | Unexpected store error | DENYSOFT |
| `ERRQ07` | Too many nested attachments | DENY |
| `DroppedByPolicy` | Filter dropped message | OK (silent) |

## Key Dependencies

| Package | Purpose |
|---------|---------|
| `@sudobility/wildduck` | WildDuck core: UserHandler, MessageHandler, FilterHandler, BimiHandler, Maildropper, autoreply, counters |
| `mailauth` | SPF, DKIM verify, ARC, DMARC, BIMI authentication |
| `mongodb` | MongoDB driver v6 for storage |
| `ioredis` | Redis client for rate limiting |
| `haraka-dsn` | SMTP DSN response creation |
| `gelf` | GELF protocol client for Graylog logging |
| `nodemailer` | Used for `addressparser` (email parsing) |
| `libmime` | MIME header parsing, encoded-word decoding |
| `srs.js` | Sender Rewriting Scheme for bounces |
| `punycode.js` | Internationalized domain encoding |
| `patch-package` | Applies `patches/` on postinstall |

**Dev**: `mocha` + `chai` + `sinon` (testing), `grunt` + plugins (runner), `eslint` + `prettier` (style), `npm-check-updates` (updates).

## Git Workflow

- Do not use feature branches for code changes. Always stay on the current branch.
