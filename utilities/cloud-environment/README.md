# The Claude Code cloud environment

This directory holds the setup of a Claude Code cloud environment for kona: `setup.sh` and this
guide. A cloud session with this environment can run each check of CI for `web/`, `api/`, and
`utilities/`. Nothing here goes to production.

Reference: <https://code.claude.com/docs/en/cloud-environments>.

## What the environment adds to the image

The Anthropic image is Ubuntu 24.04 with Ruby 3.1 to 3.3, Node 22 on `PATH`, Redis 7, and tmux.
kona needs more:

| Need | Source | Why the image is not sufficient |
|---|---|---|
| Ruby 4.0.9 | The prebuilt binary of `ruby/setup-ruby`, from GitHub releases | The image has no Ruby 4. `cache.ruby-lang.org` is not on the allowlist, thus `ruby-build` cannot get the source. |
| Node 24 | `/opt/node24` in the image, or `nodejs.org` | The image puts Node 22 first on `PATH`. |
| libvips | apt | `ruby-vips` opens it at load time, in both apps. |
| overmind | GitHub releases | `overmind start` reads `Procfile.dev`. |
| Gems | rubygems.org, and the `blurhash` git gem from GitHub | For `api`, `web`, `utilities/aqi-map`, and `utilities/race-weather`. |
| npm packages | npmjs, and Web Awesome Pro from a private registry | For `api`, `web`, and `utilities/contentful`. |
| The admin bundle of the api | `npm run build` in `api/` | Propshaft raises `MissingAssetError` without it, in about 200 specs. |

The script puts a link to each tool in `/root/.local/bin`. The image puts that directory before
`/opt/node22/bin` and `/usr/local/bin` on `PATH`. Thus each shell of Claude gets Ruby 4.0.9 and Node
24, with no change to a profile file.

⚠️ The prebuilt Ruby is not relocatable. It must stay at `/opt/hostedtoolcache/Ruby/<version>/x64`.

## Set up the environment

Do these steps at <https://claude.ai/code>. Open the environment selector below the message box,
then select **New environment**. To edit an environment that exists, use the settings icon on its
row.

### 1. Name

`kona`. Do not use the **Default** environment: each of your repos uses it.

### 2. Network access

Select **Custom**. Check **Also include default list of common package managers**. Add one domain:

```text
dl.fontawesome.com
```

The Web Awesome registry sends each package download to a signed URL on that host. The URL holds
its own signature, thus that host needs no secret.

You do not need GitHub, rubygems.org, nodejs.org, or the Ubuntu mirrors here. The GitHub proxy and
the default list cover them.

### 3. Environment variables

```text
LANG=C.UTF-8
WEBAWESOME_NPM_TOKEN=proxy-injected
```

- `LANG`: the VM has no locale. Without it, Ruby reads files as US-ASCII, and 4 specs in `web/` fail
  with `Encoding::CompatibilityError`. CI has a UTF-8 locale.
- `WEBAWESOME_NPM_TOKEN`: a placeholder and not the token. The `.npmrc` of `web/` and `api/` reads
  it, and npm stops when it has no value. The network secret in step 4 replaces the header.

⚠️ Each person who uses the environment can read these values. Never put a true key here.

### 4. Network secret

Open **Network secrets**, then **Add secret**:

| Field | Value |
|---|---|
| Host | `npm.cloudsmith.io` |
| Type | Bearer, with the header `Authorization` |
| Value | The Web Awesome Pro token: the same value as the `WEBAWESOME_NPM_TOKEN` secret of the repo in GitHub |

The proxy adds the token to each request to that host. The token never goes into the VM. The secret
also permits that host, thus do not add it to the list in step 2.

### 5. Setup script

Open **Setup script**, then **Choose file**, and select `setup.sh`. Or paste its text. Then select
**Add environment** or **Save changes**.

⚠️ The script must stay plain ASCII. The form refuses an invisible character, and the `⚠️` emoji
of the code style has one. The script must also stay at 100 lines or fewer.

### 6. Check it

Start a new session in the `kona` environment and ask Claude to run:

```bash
ruby -v && node -v && overmind -v
```

```bash
cd api && bundle exec rspec
```

```bash
cd web && bundle exec rspec && npm test && npm run check
```

```bash
cd utilities/aqi-map && ruby spec/epa_aqi_check.rb
```

A failed step of the script gives a `[kona-setup] WARNING:` line in the setup log, and the session
still starts.

## What the script does not do

- **No app secret.** The script writes no `.env`. The specs need none. `middleman build` and
  `middleman server` read Contentful at boot, thus they need `CONTENTFUL_*` values and their hosts.
  Add each one as a network secret where its API takes a header. Never use a production value for
  `REDIS_URL`. Refer to the root `CLAUDE.md`.
- **No process.** The cache keeps files, and not processes. Ask Claude to start Redis
  (`redis-server --daemonize yes`) or `overmind start` in each session that needs one.
- **No deploy.** The environment has no fly.io token and no Cloudflare token, on purpose.

## Maintenance

- **A change of the Ruby version** in `.ruby-version` needs the same change to `RUBY_VERSION` in
  `setup.sh`, and then in the environment. The prebuilt binary must exist for `ubuntu-24.04-x64`.
- **A change of the Node version** in `.nvmrc` needs a change to `NODE_MAJOR`.
- **The cache.** The script runs one time, and later sessions start from a snapshot of the disk. It
  runs again after a change to the script or to the network list, and after approximately 7 days.
  A change to a lockfile does not start it. Thus a session can start with old gems or packages. Ask
  Claude to run `bundle install` or `npm ci` in that condition.
- **The time limit.** The cache needs the script to end in approximately 5 minutes. On a new VM it
  takes approximately 1 minute 15 seconds, and most of that is the four `bundle install` runs.
