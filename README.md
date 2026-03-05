# Bespoken

> *Precision skincare, formulated for exactly one person — you.*

Bespoken is a full-stack luxury skincare platform that combines scroll-driven cinematic storytelling with a clinical skin analysis engine and a bespoke serum formulation service. Every product is formulated on-demand based on a user's unique skin biometric profile.

---

## Table of Contents

1. [Why This System](#why-this-system--a-systems-builders-perspective)
2. [Architecture Overview](#architecture-overview)
3. [System Component Diagram](#system-component-diagram)
4. [Data Flow — Skin Analysis to Order](#data-flow--skin-analysis-to-order)
5. [Auth Flow — JWT with Refresh Rotation](#auth-flow--jwt-with-refresh-token-rotation)
6. [Tech Stack](#tech-stack)
7. [Project Structure](#project-structure)
8. [Quick Start with Docker](#quick-start-with-docker)
9. [Local Development Setup](#local-development-setup)
10. [Service Ports](#service-ports)
11. [API Reference](#api-reference)
12. [Database Schema Overview](#database-schema-overview)
13. [Environment Variables](#environment-variables)
14. [Running Migrations](#running-migrations)

---

## Why This System — A Systems Builder's Perspective

Most e-commerce backends are monoliths with a product table and a checkout flow. Bespoken is something different: its core value proposition is **formulation** — a user-specific, data-rich artifact that sits at the intersection of biology, chemistry, and commerce. That single distinction drives every architectural decision in this system.

### Bounded Contexts Map Directly to Microservices

The domain naturally partitions into five bounded contexts, each with its own lifecycle, data ownership, and rate of change:

| Bounded Context | Why Separate |
|---|---|
| **Users / Auth** | Identity is cross-cutting but must be isolated. Password hashing (Argon2id), refresh token rotation, and GDPR-scope data live here and nowhere else. |
| **Catalog** | Product data is read-heavy, rarely mutated, and needs no knowledge of users. Separating it allows aggressive caching without leaking user context. |
| **Formulation** | The differentiating domain. A formulation stores a skin biometric profile, detected concerns, and ingredient recommendations — none of which belong in a product table or a user profile. Its own database means its schema can evolve independently as the science improves. |
| **Cart** | Session-scoped, write-heavy, and ephemeral. It references products and users by ID but never needs to JOIN their data. Isolation keeps it fast and lets it be replaced with a Redis-native store in the future. |
| **Orders** | Immutable, append-only records. Strict financial consistency requirements mean this service should eventually be the only one talking to a payment processor. Isolation makes that boundary clean. |

### The API Gateway Is Not a God Object

The gateway here is a deliberate **thin proxy**, not a BFF. It does three things:
1. Attaches a `x-request-id` to every request for distributed tracing.
2. Enforces CORS at the edge, so each downstream service doesn't have to.
3. Passes `Authorization` headers through without decoding them.

Each microservice validates the JWT independently. This is a conscious trade-off: it means shared JWT secrets (mitigated by tight TTLs — 15 minutes for access tokens) but avoids a synchronous auth dependency on every request. The gateway failing does not cascade to a total auth failure.

### Database Isolation Without the Operational Cost of Many Clusters

All five databases run inside a **single Postgres 15 instance** provisioned by the `init-multiple-dbs.sql` bootstrap script. This is the pragmatic middle ground:

- Each service connects only to its own database by name. Foreign keys across service boundaries are intentionally absent — referential integrity is maintained at the application layer via UUID references.
- You get the logical isolation of microservices (a schema migration in `bespoken_formulation` cannot break `bespoken_orders`) without the operational overhead of five separate Postgres containers.
- When scale demands it, each database can be extracted to its own RDS instance with a one-line environment variable change.

### The Frontend Is an Immutable Build Artifact

`VITE_API_BASE_URL` is baked into the Vite bundle at Docker build time. There is no runtime config injection, no nginx proxy to the API (the frontend container is static HTML/JS/CSS served by nginx). This means:

- The frontend image is genuinely stateless and can be distributed via a CDN.
- The API Gateway is the single origin for all dynamic traffic, making CORS configuration trivial.
- CI/CD pipelines are deterministic: the same source + the same env var always produces the same artifact.

### Scroll-Driven Video as a UX Architecture Decision

The `ScrollyTellingEngine` component uses Framer Motion's `useScroll` to scrub a brand film frame-by-frame against the user's scroll position. The video is never auto-played — it is treated as a data-bound animation. This is not a cosmetic choice: it keeps the experience entirely in the user's control (no autoplay fatigue) while maintaining cinematic quality. The video's `currentTime` is clamped at 68% of its duration to avoid a known artifact at the end, demonstrating that the system treats content assets as first-class data with known edge cases.

---

## Architecture Overview

```
┌────────────────────────────────────────────────────────────────────┐
│                          Client Layer                              │
│                                                                    │
│  React 19  ·  TypeScript  ·  Vite  ·  Framer Motion               │
│  React Router v7  ·  Lucide Icons  ·  CSS Modules                 │
│                         port :80                                   │
└───────────────────────────┬────────────────────────────────────────┘
                            │ HTTP  (VITE_API_BASE_URL)
                            ▼
┌────────────────────────────────────────────────────────────────────┐
│                         API Gateway                                │
│                        NestJS · port :3300                         │
│                                                                    │
│  • x-request-id injection          • Global exception filter      │
│  • HTTP request logging            • CORS enforcement             │
│  • Thin HTTP proxy to microservices                                │
└───┬──────────┬──────────┬──────────┬──────────┬───────────────────┘
    │          │          │          │          │
    ▼          ▼          ▼          ▼          ▼
 :3301      :3302      :3303      :3304      :3305
┌──────┐  ┌──────┐  ┌────────┐  ┌──────┐  ┌──────┐
│Users │  │Cata- │  │Formu-  │  │ Cart │  │Order-│
│& Auth│  │ log  │  │lation  │  │      │  │  s   │
└──┬───┘  └──┬───┘  └───┬────┘  └──┬───┘  └──┬───┘
   │         │           │          │          │
   ▼         ▼           ▼          ▼          ▼
┌────────────────────────────────────────────────┐
│              PostgreSQL 15                     │
│                                                │
│  bespoken_users  │ bespoken_catalog            │
│  bespoken_formulation │ bespoken_cart          │
│  bespoken_orders                               │
└────────────────────────────────────────────────┘

              ┌──────────────────────┐
              │      Redis 7         │
              │  (session / cache)   │
              └──────────────────────┘
```

---

## System Component Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Docker Network: bespoken_network                                           │
│                                                                             │
│  ┌─────────────┐    builds from    ┌──────────────────────────────────────┐ │
│  │  frontend   │◄─────────────────│  be-spoken-web/  (Vite SPA)          │ │
│  │  nginx:80   │                  └──────────────────────────────────────┘ │
│  └──────┬──────┘                                                           │
│         │ :80 (exposed)                                                    │
│         │                                                                  │
│  ┌──────▼──────────────────────────────────────────────────────────────┐   │
│  │  api-gateway  :3300 (exposed)                                       │   │
│  │  NestJS · HttpModule · RequestIdMiddleware · AllExceptionsFilter    │   │
│  └──┬────────┬────────┬───────────┬──────────┬──────────────────────┬─┘   │
│     │        │        │           │          │                      │     │
│  ┌──▼──┐  ┌──▼──┐  ┌──▼──────┐  ┌▼─────┐  ┌─▼──────┐             │     │
│  │users│  │cata-│  │formula- │  │cart  │  │orders  │             │     │
│  │3301 │  │log  │  │tion     │  │3304  │  │3305    │             │     │
│  │     │  │3302 │  │3303     │  │      │  │        │             │     │
│  │JWT  │  │     │  │         │  │JWT   │  │JWT     │             │     │
│  │Auth │  │JWT  │  │JWT      │  │Guard │  │Guard   │             │     │
│  │Argon│  │Guard│  │Guard    │  │      │  │        │             │     │
│  └──┬──┘  └──┬──┘  └────┬────┘  └──┬───┘  └────┬───┘             │     │
│     │        │           │          │            │                 │     │
│  ┌──▼────────▼───────────▼──────────▼────────────▼─────────────────▼──┐  │
│  │                     PostgreSQL 15                                   │  │
│  │  [bespoken_users] [bespoken_catalog] [bespoken_formulation]         │  │
│  │  [bespoken_cart]  [bespoken_orders]                                 │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  ┌────────────┐                                                             │
│  │  Redis 7   │ ◄── future: cart session store, rate limiting             │
│  └────────────┘                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Data Flow — Skin Analysis to Order

```
User uploads photo
        │
        ▼
[Frontend: Analysis.tsx]
  • Simulates AI scan (3-second UX)
  • Generates skin profile: hydration, sensitivity, pigmentation
  • POST /formulations  ──────────────────►  [api-gateway]
                                                    │
                                                    ▼
                                          [formulation service]
                                          • Validates JWT
                                          • Persists: userId, skinProfile (JSONB),
                                            concerns[], recommendedIngredients (JSONB)
                                          • Returns formulation.id
                                                    │
                                                    ▼
[Frontend: shows formulation.id]

User browses catalog
        │
        ▼
GET /products  ─────────────────────────►  [api-gateway]
                                                    │
                                                    ▼
                                          [catalog service]
                                          • Returns products with: sku, name,
                                            sizeMl, price, imageUrl, highlights,
                                            themeColor, gradient

User adds to cart
        │
        ▼
POST /cart/items  ──────────────────────►  [api-gateway]
                                                    │
                                                    ▼
                                          [cart service]
                                          • JWT-authenticated
                                          • Stores: userId, productId, quantity

User checks out
        │
        ▼
POST /orders  ──────────────────────────►  [api-gateway]
                                                    │
                                                    ▼
                                          [orders service]
                                          • Creates order + line items
                                          • Returns order.id
```

---

## Auth Flow — JWT with Refresh Token Rotation

```
POST /auth/register
        │
        ▼
[users service]
  • Hash password with Argon2id
  • Persist user row
        │
        ▼
POST /auth/login
        │
        ▼
[users service]
  • Verify password with Argon2id
  • Issue access token  (JWT, 15min TTL, signed with JWT_ACCESS_SECRET)
  • Issue refresh token (JWT, 14day TTL, signed with JWT_REFRESH_SECRET)
  • Store refresh token HASH (Argon2id) in users.refresh_token_hash
  • Set refresh token in httpOnly cookie
  • Return access token in response body

Client stores accessToken in localStorage
        │
        ▼
Every API request:
  Authorization: Bearer <accessToken>  ──►  [api-gateway passes through]
                                                    │
                                                    ▼
                                          [downstream service]
                                          • JwtAuthGuard validates signature
                                          • Extracts userId from payload

On 401 (token expired):
        │
        ▼
POST /auth/refresh (cookie sent automatically)
        │
        ▼
[users service]
  • Verify refresh token signature
  • Compare against stored hash
  • Issue new access + refresh token pair  (rotation)
  • Invalidate old refresh token hash
        │
        ▼
Client retries original request with new access token
```

---

## Tech Stack

### Frontend

| Concern | Choice | Why |
|---|---|---|
| Framework | React 19 | Concurrent mode, latest patterns |
| Build tool | Vite 7 | Sub-second HMR, ESM-first |
| Language | TypeScript 5.9 | Full type safety across the API contract |
| Animation | Framer Motion 12 | `useScroll` + `useMotionValueEvent` for scroll-scrubbed video |
| Routing | React Router 7 | File-system-style declarative routing |
| Icons | Lucide React | Lightweight, tree-shakeable |
| Styling | CSS Modules + CSS custom properties | Scoped styles without a runtime |

### Backend

| Concern | Choice | Why |
|---|---|---|
| Framework | NestJS 11 | Dependency injection, decorators, monorepo support via `nest-cli.json` |
| Language | TypeScript 5.7 | Shared types, strict compilation |
| ORM | TypeORM 0.3 | Migrations, entity decorators, native Postgres JSONB |
| Auth | Passport JWT + Argon2id | Industry-standard JWT, memory-hard password hashing |
| HTTP Client | `@nestjs/axios` | RxJS-based async HTTP for gateway proxying |
| Validation | `class-validator` + `class-transformer` | DTO-level validation with transformation |

### Infrastructure

| Concern | Choice |
|---|---|
| Database | PostgreSQL 15 (multi-database, single instance) |
| Cache / Session | Redis 7 |
| Containerisation | Docker + Docker Compose v3.8 |
| Frontend serving | nginx 1.27-alpine |
| Node runtime | Node 22-alpine (multi-stage builds) |

---

## Project Structure

```
Bespoken-Github/
├── README.md
├── docker-compose.yml              # Full-stack orchestration
├── .env.example                    # Template for secrets
├── .gitignore
│
├── docker/
│   ├── backend.Dockerfile          # Multi-stage build (SERVICE build-arg)
│   ├── frontend.Dockerfile         # Vite build → nginx
│   ├── nginx.conf                  # SPA routing + asset caching
│   └── init-multiple-dbs.sql       # Bootstrap 5 Postgres databases
│
├── be-spoken-web/                  # React frontend
│   ├── src/
│   │   ├── api/
│   │   │   ├── client.ts           # apiFetch wrapper with token refresh
│   │   │   └── products.ts
│   │   ├── components/
│   │   │   ├── home/
│   │   │   │   ├── ScrollyTellingEngine.tsx   # Scroll-scrubbed brand video
│   │   │   │   └── CommerceReveal.tsx
│   │   │   └── layout/
│   │   │       ├── Navbar.tsx
│   │   │       └── Footer.tsx
│   │   ├── context/
│   │   │   ├── AuthContext.tsx      # Global auth state
│   │   │   └── CartContext.tsx      # Global cart state
│   │   └── pages/
│   │       ├── Home.tsx
│   │       ├── Analysis.tsx         # Skin scan + formulation save
│   │       ├── Products.tsx
│   │       ├── Cart.tsx
│   │       ├── Login.tsx / Register.tsx
│   │       └── Account/             # Profile, skin profile, order history
│   └── public/assets/               # Brand video, product imagery
│
└── bespoken-backend/               # NestJS monorepo
    ├── nest-cli.json                # Monorepo project registry
    └── apps/
        ├── api-gateway/            # Single ingress — thin HTTP proxy
        │   └── src/
        │       ├── auth.controller.ts
        │       ├── catalog.controller.ts
        │       ├── cart.controller.ts
        │       ├── formulation.controller.ts
        │       ├── orders.controller.ts
        │       └── common/
        │           ├── request-id.middleware.ts
        │           ├── http-logger.middleware.ts
        │           └── all-exceptions.filter.ts
        │
        ├── users/                  # Identity, auth, profile
        │   └── src/
        │       ├── user.entity.ts  # uuid, email, skinProfile (JSONB), addresses (JSONB)
        │       ├── auth/
        │       │   ├── auth.service.ts    # Argon2 + JWT issuance + rotation
        │       │   └── jwt.strategy.ts
        │       └── migrations/
        │
        ├── catalog/                # Products
        │   └── src/
        │       ├── product.entity.ts  # sku, price, highlights[], themeColor, gradient
        │       └── migrations/
        │
        ├── formulation/            # Skin profiles + ingredient recommendations
        │   └── src/
        │       ├── formulation.entity.ts  # skinProfile, concerns, recommendedIngredients (JSONB)
        │       └── migrations/
        │
        ├── cart/                   # User shopping carts
        │   └── src/
        │       ├── cart-item.entity.ts
        │       └── migrations/
        │
        └── orders/                 # Order records
            └── src/
                ├── order.entity.ts
                ├── order-item.entity.ts
                └── migrations/
```

---

## Quick Start with Docker

### Prerequisites

- Docker 24+ and Docker Compose v2
- No Node.js required locally

### 1. Clone and configure

```bash
git clone https://github.com/your-org/bespoken.git
cd bespoken

cp .env.example .env
# Open .env and replace all placeholder values
# At minimum, set strong values for:
#   DB_PASSWORD, JWT_ACCESS_SECRET, JWT_REFRESH_SECRET
```

### 2. Start the full stack

```bash
docker compose up --build
```

This will:
- Start PostgreSQL and wait for it to be healthy
- Create all 5 databases via the init script
- Build and start all 5 NestJS microservices (each runs its own TypeORM migrations on startup)
- Build and start the API Gateway
- Build the Vite frontend and serve it via nginx

### 3. Open the app

| Service | URL |
|---|---|
| Frontend | http://localhost |
| API Gateway | http://localhost:3300 |
| PostgreSQL | localhost:5432 (configurable via `DB_PORT_EXPOSE`) |
| Redis | localhost:6379 (configurable via `REDIS_PORT_EXPOSE`) |

### Useful compose commands

```bash
# View logs for all services
docker compose logs -f

# View logs for a specific service
docker compose logs -f api-gateway

# Restart a single service after code change
docker compose up --build users

# Stop everything and remove volumes (destructive — clears the database)
docker compose down -v

# Stop everything but keep volumes (data persists)
docker compose down
```

---

## Local Development Setup

For active development you will want hot-reload. Run the infrastructure via Docker and the services locally.

### 1. Start only infrastructure

```bash
docker compose up postgres redis
```

### 2. Backend

```bash
cd bespoken-backend
cp .env.example .env.local   # adjust DB_HOST to localhost

npm install

# Run all microservices with hot reload
npm run start:all
```

Individual services:

```bash
npm run start:dev api-gateway
npm run start:dev users
npm run start:dev catalog
npm run start:dev formulation
npm run start:dev cart
npm run start:dev orders
```

### 3. Frontend

```bash
cd be-spoken-web
cp .env.example .env.local

npm install
npm run dev
```

The Vite dev server starts at http://localhost:5173 with HMR.

---

## Service Ports

| Service | Default Port | Description |
|---|---|---|
| Frontend (nginx) | 80 | React SPA |
| API Gateway | 3300 | Single entry point for all client traffic |
| Users | 3301 | Auth, registration, profile management |
| Catalog | 3302 | Product listings |
| Formulation | 3303 | Skin profiles and ingredient recommendations |
| Cart | 3304 | Shopping cart items |
| Orders | 3305 | Order placement and history |
| PostgreSQL | 5432 | Shared DB instance (5 databases) |
| Redis | 6379 | Cache and session layer |

---

## API Reference

All requests go through `POST/GET http://localhost:3300`. The gateway forwards to the appropriate service and passes through the `Authorization` header.

### Auth

```
POST /auth/register
Body: { username, email, password }

POST /auth/login
Body: { email, password }
Response: { accessToken }  +  Set-Cookie: refresh token (httpOnly)

POST /auth/refresh
Cookie: refresh token
Response: { accessToken }

POST /auth/logout
Clears refresh token cookie and invalidates stored hash
```

### Users

```
GET  /users/me                    # Requires: Bearer token
PATCH /users/me                   # Update profile fields
```

### Catalog

```
GET  /products                    # Public
GET  /products/:id                # Public
POST /products                    # Admin (JWT required)
```

### Formulation

```
GET  /formulations                # Requires: Bearer token — list user's formulations
GET  /formulations/:id            # Requires: Bearer token
POST /formulations                # Requires: Bearer token
Body: {
  status: "Draft" | "Completed",
  skinProfile: { hydration, sensitivity, pigmentation },
  concerns: string[],
  recommendedIngredients: { [ingredient: string]: string }
}
```

### Cart

```
GET    /cart                      # Requires: Bearer token
POST   /cart/items                # Add item
PATCH  /cart/items/:id            # Update quantity
DELETE /cart/items/:id            # Remove item
```

### Orders

```
GET  /orders                      # Requires: Bearer token
GET  /orders/:id                  # Requires: Bearer token
POST /orders                      # Create order from cart
```

---

## Database Schema Overview

### `bespoken_users` — users table

| Column | Type | Notes |
|---|---|---|
| id | uuid | PK |
| username | varchar | unique |
| email | varchar | unique |
| password_hash | varchar | Argon2id |
| refresh_token_hash | varchar | nullable, rotated on each refresh |
| skin_profile | jsonb | `{ hydration, sensitivity, pigmentation }` |
| addresses | jsonb | `Address[]` |
| full_name, phone, gender, age, birthday, anniversary, nationality, social | varchar/int | Profile fields |
| last_login_at | timestamptz | |
| created_at / updated_at | timestamptz | Auto-managed |

### `bespoken_catalog` — products table

| Column | Type | Notes |
|---|---|---|
| id | uuid | PK |
| sku | varchar | unique |
| name | varchar | |
| description | text | nullable |
| size_ml | int | |
| price | int | in cents |
| currency | varchar | default USD |
| image_url / video_url | varchar | nullable |
| theme_color / gradient | varchar | nullable, for UI theming |
| highlights | jsonb | `string[]` |
| is_active | boolean | default true |

### `bespoken_formulation` — formulations table

| Column | Type | Notes |
|---|---|---|
| id | uuid | PK |
| user_id | uuid | FK reference to users (by convention) |
| status | varchar | `Draft` or `Completed` |
| skin_profile | jsonb | Detected attributes |
| concerns | jsonb | `string[]` |
| recommended_ingredients | jsonb | `{ [ingredient]: concentration }` |
| created_at / updated_at | timestamptz | |

### `bespoken_cart` — cart_items table

| Column | Type | Notes |
|---|---|---|
| id | uuid | PK |
| user_id | uuid | |
| product_id | uuid | |
| quantity | int | |

### `bespoken_orders` — orders + order_items tables

| Column | Type | Notes |
|---|---|---|
| order.id | uuid | PK |
| order.user_id | uuid | |
| order.status | varchar | pending / confirmed / shipped |
| order.total | int | in cents |
| order_item.order_id | uuid | FK → orders |
| order_item.product_id | uuid | |
| order_item.quantity / unit_price | int | |

---

## Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `DB_USER` | Yes | `bespoken` | Postgres superuser |
| `DB_PASSWORD` | Yes | — | Postgres password |
| `DB_PORT_EXPOSE` | No | `5432` | Host port for Postgres |
| `REDIS_PORT_EXPOSE` | No | `6379` | Host port for Redis |
| `JWT_ACCESS_SECRET` | Yes | — | Min 32 chars, signs access tokens |
| `JWT_REFRESH_SECRET` | Yes | — | Min 32 chars, signs refresh tokens |
| `JWT_ACCESS_TTL_SECONDS` | No | `900` | 15 minutes |
| `JWT_REFRESH_TTL_SECONDS` | No | `1209600` | 14 days |
| `CORS_ORIGINS` | Yes | — | Comma-separated allowed origins |
| `COOKIE_SECURE` | No | `false` | Set `true` in production (requires HTTPS) |
| `COOKIE_DOMAIN` | No | — | Domain for refresh token cookie |
| `VITE_API_BASE_URL` | Yes | `http://localhost:3300` | Baked into the frontend bundle at build time |

Generate secrets:

```bash
openssl rand -hex 64   # run twice — one for each JWT secret
```

---

## Running Migrations

Each service runs its TypeORM migrations automatically on startup when `DB_RUN_MIGRATIONS=true`.

To run migrations manually from the backend directory:

```bash
# Users
npm run migration:users:run

# Catalog
npm run migration:catalog:run

# Formulation
npm run migration:formulation:run

# Cart
npm run migration:cart:run

# Orders
npm run migration:orders:run
```

To revert the last migration:

```bash
npm run migration:users:revert
```

To generate a new migration after changing an entity:

```bash
npm run migration:users:generate
```

---

*Built with precision. Made only for you.*
