#!/bin/bash
# The setup script of the Claude Code cloud environment for kona. Refer to README.md.
# It cannot read the variables of the environment, and it must exit 0, or no session starts.

set -uo pipefail

RUBY_VERSION=4.0.9
# The prebuilt Ruby is not relocatable: its scripts and its libruby path name this prefix.
RUBY_DIR=/opt/hostedtoolcache/Ruby/$RUBY_VERSION/x64
NODE_MAJOR=24
NODE_DIR=/opt/node$NODE_MAJOR
OVERMIND_VERSION=2.5.1
# The image puts this dir before /opt/node22/bin and /usr/local/bin on PATH. A link here thus
# selects the tool for each shell of Claude, with no change to a profile file.
LINK_DIR=/root/.local/bin

export NPM_CONFIG_UPDATE_NOTIFIER=false
log() { echo "[kona-setup] $*"; }
warn() { echo "[kona-setup] WARNING: $*" >&2; }

if [ -d kona ]; then REPO="$PWD/kona"
elif [ -f CLAUDE.md ] && [ -d web ] && [ -d api ]; then REPO="$PWD"
else log "No kona checkout here. Nothing to do."; exit 0
fi
log "Repo: $REPO"
mkdir -p "$LINK_DIR"

# libvips: ruby-vips opens it at load time, in web and in api.
if ! ldconfig -p | grep -q 'libvips\.so\.42'; then
  log "Installing libvips"
  { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends libvips; } \
    || warn "libvips install failed: web and api specs will not load"
fi

# Ruby: the image has 3.1 to 3.3 only. Use the prebuilt binary of ruby/setup-ruby, from GitHub
# releases. Do not compile with ruby-build: cache.ruby-lang.org is not on the default allowlist.
if [ ! -x "$RUBY_DIR/bin/ruby" ]; then
  log "Installing Ruby $RUBY_VERSION"
  mkdir -p "$RUBY_DIR"
  curl -fsSL "https://github.com/ruby/ruby-builder/releases/download/ruby-$RUBY_VERSION/ruby-$RUBY_VERSION-ubuntu-24.04-x64.tar.gz" \
    | tar -xz --strip-components=1 -C "$RUBY_DIR" \
    || { warn "Ruby $RUBY_VERSION download failed"; rm -rf "$RUBY_DIR"; }
fi

# Node: the image has /opt/node24, but PATH selects node22. Get it from nodejs.org if absent.
if [ ! -x "$NODE_DIR/bin/node" ]; then
  log "Installing Node $NODE_MAJOR"
  file=$(curl -fsSL "https://nodejs.org/dist/latest-v$NODE_MAJOR.x/SHASUMS256.txt" | awk '/linux-x64.tar.xz$/ {print $2}')
  mkdir -p "$NODE_DIR"
  curl -fsSL "https://nodejs.org/dist/latest-v$NODE_MAJOR.x/$file" | tar -xJ --strip-components=1 -C "$NODE_DIR" \
    || { warn "Node $NODE_MAJOR download failed"; rm -rf "$NODE_DIR"; }
fi
for f in node npm npx corepack; do
  [ -e "$NODE_DIR/bin/$f" ] && ln -sf "$NODE_DIR/bin/$f" "$LINK_DIR/$f"
done

# overmind, for `overmind start` (tmux is in the image).
if [ ! -x "$LINK_DIR/overmind" ]; then
  log "Installing overmind $OVERMIND_VERSION"
  curl -fsSL "https://github.com/DarthSim/overmind/releases/download/v$OVERMIND_VERSION/overmind-v$OVERMIND_VERSION-linux-amd64.gz" \
    | gunzip > "$LINK_DIR/overmind" && chmod +x "$LINK_DIR/overmind" \
    || { warn "overmind install failed"; rm -f "$LINK_DIR/overmind"; }
fi
export PATH="$LINK_DIR:$RUBY_DIR/bin:$NODE_DIR/bin:$PATH"

# One app at a time: two parallel runs write the same gem dir.
if [ -x "$RUBY_DIR/bin/ruby" ]; then
  export BUNDLE_JOBS=4 BUNDLE_RETRY=3 BUNDLE_SILENCE_ROOT_WARNING=1
  for app in api web utilities/aqi-map utilities/race-weather; do
    [ -f "$REPO/$app/Gemfile" ] || continue
    log "bundle install: $app"
    (cd "$REPO/$app" && bundle install --quiet) || warn "bundle install failed in $app"
  done
  # Link last, thus the gem executables are included.
  for f in "$RUBY_DIR"/bin/*; do ln -sf "$f" "$LINK_DIR/$(basename "$f")"; done
fi

# web and api need Web Awesome Pro from npm.cloudsmith.io. A network secret adds the true token
# there. The .npmrc files need only a value in WEBAWESOME_NPM_TOKEN.
export WEBAWESOME_NPM_TOKEN=proxy-injected
registry_ok=$(curl -s -o /dev/null -w '%{http_code}' https://npm.cloudsmith.io/fortawesome/webawesome-pro/ || true)
for app in api web utilities/contentful; do
  [ -f "$REPO/$app/package-lock.json" ] || continue
  if [ "$app" != utilities/contentful ] && [ "$registry_ok" = 000 ]; then
    warn "npm.cloudsmith.io is not reachable. Skipping npm ci in $app. Add the network secret."
    continue
  fi
  log "npm ci: $app"
  (cd "$REPO/$app" && npm ci --no-audit --no-fund --loglevel=error) || warn "npm ci failed in $app"
done

# The admin bundle of the api. Propshaft raises MissingAssetError without it, in specs too.
if [ -d "$REPO/api/node_modules" ]; then
  log "npm run build: api"
  (cd "$REPO/api" && npm run build --silent) || warn "api asset build failed"
fi

log "Done. ruby: $(ruby -v 2>/dev/null | cut -d' ' -f2), node: $(node -v 2>/dev/null)"
exit 0
