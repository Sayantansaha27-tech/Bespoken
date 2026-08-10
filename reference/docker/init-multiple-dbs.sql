-- Initialises all per-service databases under the shared Postgres instance.
-- This script runs automatically on first container start via the
-- docker-entrypoint-initdb.d mechanism.

CREATE DATABASE bespoken_users     OWNER bespoken;
CREATE DATABASE bespoken_catalog   OWNER bespoken;
CREATE DATABASE bespoken_formulation OWNER bespoken;
CREATE DATABASE bespoken_cart      OWNER bespoken;
CREATE DATABASE bespoken_orders    OWNER bespoken;
