# syntax=docker/dockerfile:1
# Multi-stage build for the kona-og service, mirroring api/Dockerfile's conventions
# (slim base, deps installed in a build stage, non-root runtime user, EXPOSE the fly
# internal_port). Deployed to fly.io as `kona-og`; see og/fly.toml.

# node:lts tracks the same Node LTS line as og/.nvmrc, so local, CI, and the image agree.
FROM node:lts-slim AS build
WORKDIR /app

# Install production deps from the lockfile for a reproducible image.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

# App source (server, renderer, title fetcher, baked font + logo assets).
COPY . .

FROM node:lts-slim
WORKDIR /app
ENV NODE_ENV=production

COPY --from=build /app /app

EXPOSE 3000
USER node
CMD ["node", "server.mjs"]
