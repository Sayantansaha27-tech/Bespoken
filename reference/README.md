# Reference deployment topology

These files document how Bespoken was deployed. They are reference material, not a
runnable build: the Dockerfiles copy from `bespoken-backend/` and `be-spoken-web/`,
application source trees that are not published in this repository.

What these files record:

| File | What it documents |
|---|---|
| `docker-compose.yml` | The nine-service topology: Postgres, Redis, five NestJS services, API gateway, nginx frontend |
| `docker/init-multiple-dbs.sql` | Bootstrap that provisions five isolated databases inside one Postgres instance |
| `docker/backend.Dockerfile` | Multi-stage NestJS build, parameterised by `SERVICE` build arg |
| `docker/frontend.Dockerfile` | Vite build with `VITE_API_BASE_URL` baked in, served by nginx |
| `docker/nginx.conf` | Static asset serving and SPA fallback |

`init-multiple-dbs.sql` and `nginx.conf` are complete and directly reusable. The two
Dockerfiles and the five application services in the Compose file are not buildable
without the source.
