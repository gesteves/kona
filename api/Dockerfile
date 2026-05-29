# syntax=docker/dockerfile:1
# Production Dockerfile for Fly.io (kona-api).
#
# Build the image locally with:
#   docker build -t kona-api .
# and run it with:
#   docker run -d -p 3000:3000 -e RAILS_MASTER_KEY=<value from config/master.key> --name kona-api kona-api

ARG RUBY_VERSION=4.0.5
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

# Install application gems
COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

# Copy application code
COPY . .


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
