# ─────────────────────────────────────────────────────────────────────────────
# Multi-stage build for any Bespoken backend microservice.
# Pass SERVICE build-arg to select which app to compile (e.g. api-gateway, users, catalog...).
# ─────────────────────────────────────────────────────────────────────────────

ARG SERVICE=api-gateway

# ── Stage 1: Build ────────────────────────────────────────────────────────────
FROM node:22-alpine AS builder

ARG SERVICE
WORKDIR /app

# Install dependencies first (better layer caching)
COPY bespoken-backend/package*.json bespoken-backend/nest-cli.json bespoken-backend/tsconfig*.json ./
RUN npm ci --frozen-lockfile

# Copy application source
COPY bespoken-backend/apps ./apps

# Compile the selected service
RUN npx nest build ${SERVICE}

# ── Stage 2: Production runner ────────────────────────────────────────────────
FROM node:22-alpine AS runner

ARG SERVICE
WORKDIR /app

# Copy compiled output for the selected service only
COPY --from=builder /app/dist/apps/${SERVICE} ./dist/

# Copy production node_modules (native addons like argon2/pg cannot be bundled)
COPY --from=builder /app/node_modules ./node_modules

# Run as non-root
RUN addgroup -S bespoken && adduser -S bespoken -G bespoken
USER bespoken

CMD ["node", "dist/main.js"]
