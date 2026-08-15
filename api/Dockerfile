# syntax=docker/dockerfile:1
# Production Dockerfile for Fly.io (kona-api).
#
# Build the image locally with:
#   docker build -t kona-api --secret id=WEBAWESOME_NPM_TOKEN,env=WEBAWESOME_NPM_TOKEN .
# and run it with:
#   docker run -d -p 3000:3000 -e RAILS_MASTER_KEY=<value from config/master.key> --name kona-api kona-api
#
# ⚠️ The build needs WEBAWESOME_NPM_TOKEN — the admin UI's Web Awesome Pro package comes from a
# private registry. CI passes it with `flyctl deploy --build-secret`.

ARG RUBY_VERSION=4.0.6
# ⚠️ Keep this in step with .nvmrc (`lts/*`), which is what CI and local dev resolve.
ARG NODE_VERSION=24

# Node comes from the official image rather than apt (Debian's is far too old) or a source build
# (minutes per deploy). Only the build stage borrows from it; the final image stays Ruby-only.
FROM docker.io/library/node:$NODE_VERSION-slim AS node

FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages needed at runtime
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libyaml-0-2 && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test"


# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# ⚠️ This borrows a binary built against the node image's glibc. Both images are Debian slim and
# track the same stable release, so they agree today — but if they ever diverge this is where it
# breaks, which is why the versions are asserted immediately rather than failing later inside
# `npm ci` with an error that looks nothing like its cause.
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm && \
    node --version && npm --version

# Install application gems
COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile --gemfile

# Install JavaScript dependencies. .npmrc interpolates the token from the environment, so mounting
# it as a build secret keeps it out of the image and its layer history. Reading /run/secrets/…
# works on every BuildKit version, unlike the newer `env=` mount option.
COPY package.json package-lock.json .npmrc ./
RUN --mount=type=secret,id=WEBAWESOME_NPM_TOKEN \
    WEBAWESOME_NPM_TOKEN="$(cat /run/secrets/WEBAWESOME_NPM_TOKEN)" npm ci

# Copy application code
COPY . .

# Precompile bootsnap cache for app code so it ships in the image
RUN bundle exec bootsnap precompile app/ lib/

# Build the admin bundle (jsbundling-rails runs `npm run build`) and fingerprint it into
# public/assets. SECRET_KEY_BASE_DUMMY is required because .dockerignore excludes config/master.key.
#
# ⚠️ node_modules must go here, before the final stage copies /rails wholesale. Left behind it
# ships ~100MB of build-only dependencies to a 512MB shared-cpu VM with a documented OOM history.
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile && \
    rm -rf node_modules


# Final stage for app image
FROM base

# Copy built artifacts: gems, application
COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /rails /rails

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    mkdir -p log tmp && \
    chown -R rails:rails log tmp
USER 1000:1000

# Start the server by default; this can be overwritten at runtime
EXPOSE 3000
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
