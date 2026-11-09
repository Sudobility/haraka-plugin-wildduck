# WildDuck plugin for Haraka

A [Haraka](https://haraka.github.io/) SMTP-server plugin that handles the
complete inbound email pipeline for the [WildDuck](https://wildduck.email/)
mail server. On a running Haraka MX it:

- normalizes recipient addresses and validates them against the WildDuck
  users table in MongoDB (unknown recipients are rejected);
- performs email authentication — SPF, DKIM, ARC, DMARC and BIMI — via
  [`mailauth`](https://www.npmjs.com/package/mailauth);
- enforces per-recipient / per-IP rate limits using Redis TTL counters;
- checks mailbox quota and rejects when it is exceeded;
- handles address forwarding (and SRS bounce rewriting), autoreplies, and
  optional spam routing from Rspamd output;
- stores delivered messages into MongoDB (GridFS for attachments) and queues
  forwards/autoreplies to ZoneMTA.

This is the only delivery plugin you need to run Haraka with WildDuck. It
already includes SPF and DKIM support, so **do not** enable Haraka's built-in
`spf` or `dkim_verify` plugins (or any other delivery plugin) alongside it.

> This repository is the `@sudobility/haraka` fork of the upstream
> `haraka-plugin-wildduck`, part of the Zone Mail Suite (ZMS).

- **Package**: `@sudobility/haraka`
- **License**: Business Source License 1.1 (BUSL-1.1) — see [`LICENSE`](LICENSE)
- **Runtime**: Node.js >= 16.20.1
- **Language**: JavaScript (CommonJS)

## Repository layout

```
index.js                 # Main plugin: all SMTP hooks and processing (~2000 lines)
lib/auth.js              # Email auth (SPF/DKIM/ARC/DMARC/BIMI) via mailauth
lib/db.js                # MongoDB/Redis connections and WildDuck handler init
lib/hooks.js             # Thin Haraka hook wrappers (mail, data_post)
lib/stream-collect.js    # Transform stream that buffers message chunks for reuse
config/wildduck.yaml     # Plugin configuration (DB, rate limits, spam, auth, SRS)
test/                    # Mocha + Chai + Sinon unit tests (no live DB required)
patches/                 # patch-package patches applied on postinstall
Dockerfile               # Multi-stage image: Haraka v3.1.1 + this plugin
ARCHITECTURE.md          # Detailed architecture guide
CLAUDE.md                # Guide for AI-assisted development
```

## Install

`@sudobility/*` packages are published to **GitHub Packages**, not npmjs. The
included [`.npmrc`](.npmrc) routes the `@sudobility` scope there; installing the
scoped packages requires a GitHub token with `read:packages`.

Install into an existing Haraka instance:

```sh
cd /path/to/local/haraka
npm install @sudobility/haraka       # requires GitHub Packages auth
echo "wildduck" >> config/plugins    # must be listed LAST
service haraka restart
```

Haraka strips the `haraka-plugin-` prefix, so the plugin is referenced as
`wildduck` in `config/plugins`.

### Docker (primary deployment)

The [`Dockerfile`](Dockerfile) builds a self-contained image: it clones Haraka
`v3.1.1`, copies this repo into its `node_modules`, and installs dependencies.
It needs a `GH_PACKAGES_TOKEN` build arg to pull `@sudobility` packages:

```sh
docker build --build-arg GH_PACKAGES_TOKEN=<github-token> -t haraka-wildduck .
```

## Configuration

Copy the sample config into your Haraka `config/` directory and edit it:

```sh
cp node_modules/@sudobility/haraka/config/wildduck.yaml config/wildduck.yaml
$EDITOR config/wildduck.yaml
```

`config/wildduck.yaml` covers Redis (incl. Sentinel), MongoDB connection URLs
(messages / users / gridfs / sender queue), the ZoneMTA `sender` queue, `srs`
secret (must match ZoneMTA), rate `limits`, `gelf` logging, `rspamd`
blacklist/softlist routing, and `auth` DNS/key policy. Sensible defaults assume
an unauthenticated MongoDB and Redis on localhost.

### Antispam (optional)

WildDuck consumes the output of
[Haraka's Rspamd plugin](https://www.npmjs.com/package/haraka-plugin-rspamd):
messages tagged in `rspamd.blacklist` are rejected, those in `rspamd.softlist`
are soft-rejected, and spam is routed to the Junk mailbox.

## Development

```sh
npm install           # installs deps; postinstall runs patch-package
npm run lint          # ESLint over *.js and lib/
npm run lint:fix      # ESLint with --fix
npm run test:unit     # Grunt default: ESLint + Mocha unit tests
npx grunt test        # Mocha only (skip lint)
```

> There is no `npm test` script — use `npm run test:unit`.

Tests use Mocha + Chai + Sinon and mock Haraka connection/transaction objects,
so no running MongoDB/Redis is required. Code style is enforced by Prettier
(160-col width, 4-space indent, single quotes, LF).

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the full SMTP hook flow and
[`CLAUDE.md`](CLAUDE.md) for an AI-assisted-development quick reference.

## License

Business Source License 1.1 (BUSL-1.1). See [`LICENSE`](LICENSE) for the full
text and change date.
