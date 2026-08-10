# ─────────────────────────────────────────────────────────────────────────────
# Multi-stage build for the Bespoken React frontend.
# VITE_API_BASE_URL is baked in at build time — pass it as a build-arg.
# ─────────────────────────────────────────────────────────────────────────────

ARG VITE_API_BASE_URL=http://localhost:3300

# ── Stage 1: Build ────────────────────────────────────────────────────────────
FROM node:22-alpine AS builder

ARG VITE_API_BASE_URL
ENV VITE_API_BASE_URL=${VITE_API_BASE_URL}

WORKDIR /app

COPY be-spoken-web/package*.json ./
RUN npm ci --frozen-lockfile

COPY be-spoken-web/ .
RUN npm run build

# ── Stage 2: Serve with nginx ─────────────────────────────────────────────────
FROM nginx:1.27-alpine AS runner

COPY --from=builder /app/dist /usr/share/nginx/html
COPY docker/nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
