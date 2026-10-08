
# GoMove Engineering Guide

## Project identity

- GoMove is an academic ride-hailing platform with a Java/Spring modular-monolith backend in `backend/` and a Flutter app in `mobile/`.
- Backend uses Java 21, Spring Boot 3.5.16, Maven Wrapper, Spring Data JPA, Spring Security, PostgreSQL/PostGIS, Hibernate Spatial and Flyway. Docker Compose configures `postgis/postgis:16-3.5`; backend integration tests use Testcontainers. The repository is hosted on GitHub.
- Mobile declares Dart `>=3.3.0` and Flutter `>=3.19.0`, and uses Flutter BLoC (`flutter_bloc` 8.x).
- Use source, migrations and build configuration as the authority; do not infer missing capabilities.

## Engineering principles

- Keep the modular monolith and module boundaries. Separate API, domain, application/service and infrastructure responsibilities in the style already used by the module.
- Apply Clean Architecture and SOLID where they help; introduce patterns only to solve a concrete problem.
- Treat PostgreSQL as the source of truth. Make transaction boundaries explicit, keep them short, and perform external HTTP calls outside database transactions.
- Avoid unnecessary services, dependencies, microservices and infrastructure. Preserve existing API response and error conventions.

## Identity and security

- Persistence entities use internal `BIGINT` IDs and public UUIDs. Expose public UUIDs in APIs; do not serialize internal IDs or persistence entities.
- Derive the current user and role from the authenticated JWT/SecurityContext. Never trust request-body identity or role fields.
- Enforce role authorization and resource ownership on every protected operation. Mask another user's resource where the API's existing policy requires it.
- Never expose passwords, password hashes, signing keys or internal entity details in API responses or logs. Return access/refresh tokens only through intended authentication endpoints to authorized clients; never log tokens or expose them to other users.
- Preserve stateless JWT authentication, BCrypt cost 12, and the existing locked refresh-token rotation/revocation behavior. Add tests when changing these invariants.

## Database and spatial rules

- Never edit an existing Flyway migration. Add a new migration for schema changes; migration files are present through V9.
- Use PostgreSQL/PostGIS behavior in integration tests, not H2. Follow the shared Testcontainers setup in `BaseIntegrationTest`.
- Store geographic points as `GEOGRAPHY(Point,4326)`. Construct points in longitude, latitude order; validate API coordinates as latitude/longitude and report spatial distances in meters.
- Add GiST indexes for spatial query paths where needed, and verify query plans or behavior with PostgreSQL integration tests.
- Keep database constraints for important ownership, lifecycle, precision and financial invariants.

## Money and Quote rules

- Use `BigDecimal` for monetary arithmetic and PostgreSQL `NUMERIC` for persisted money. Never use `float` or `double` for currency.
- Preserve the complete immutable pricing snapshot, including inputs, engine version, raw calculations, displayed lines and rounding reconciliation.
- Quote TTL is exactly 60 seconds from server issuance time after routing and pricing. A quote is valid only while current time is strictly before `expiresAt`.
- The customer-visible components must reconcile exactly to `finalFare`, including `surgeAmount`, discount and `roundingAdjustment`. Keep VND rounding explicit and deterministic.
- Future Booking must consume a Quote atomically with Booking creation, checking both state and expiry in the same database transaction. V9 has no public Quote-consumption operation.

## Booking and idempotency (future work)

- Require an `Idempotency-Key`, scoped to customer identity and a canonical request hash. Check it before consuming a Quote; reject key reuse with a different request and return the original outcome for equivalent retries.
- Ensure one Quote cannot produce multiple successful Bookings. Persist idempotency, Quote consumption and Booking creation atomically; use database constraints, locks or conditional updates to handle concurrency.

## Driver and dispatch (future work)

- Preserve the existing approval states (`PENDING`, `APPROVED`, `REJECTED`, `SUSPENDED`) and operating states (`OFFLINE`, `ONLINE`, `BUSY`).
- Dispatch only approved, online drivers with an eligible active vehicle and fresh location. Nearby search already uses PostGIS, active vehicles and a freshness cutoff; build on those rules.
- Offer drivers sequentially, one at a time, with a 15-second lease. An offer is not an assignment.
- Accept an offer through an atomic conditional database transition; reject expired, duplicate and competing accepts. Set a driver to `BUSY` only when assignment succeeds.

## Trip and realtime (future work)

- Enforce valid Booking and Trip state transitions in the database-backed application flow.
- Treat WebSocket as transport, not source of truth. Authenticate and authorize connections, subscriptions and messages; only trip participants may read or publish trip locations.
- Do not expose another user's trip or location data.

## Cash payment and settlement (future work)

- Cash is physically collected by the driver. Never create virtual wallet earnings to represent cash received.
- Track platform commission as an auditable debt/receivable or commission-deposit ledger. Make financial records immutable where required and prevent duplicate cash or commission accounting.

## AI agent boundaries

- Backend tasks modify `backend/`; mobile tasks modify `mobile/`; infrastructure tasks modify only the relevant configuration. Workspace-governance tasks may modify only their assigned instruction files.
- Do not refactor unrelated modules, change historical migrations, or add dependencies or paid services without explicit authorization.
- Do not install arbitrary external agents or run third-party scripts without review. These instruction files do not create or invoke subagents.
- Never commit, push, merge or deploy without explicit permission.

## Verification

- Inspect the relevant source, tests, migrations and Git state before editing. Preserve existing uncommitted work.
- Run tests that cover the changed behavior and report actual command output. Do not claim tests were run when they were not.
- Backend verification: `cd backend` then `./mvnw clean test` (Windows: `mvnw.cmd clean test`). Flutter verification: `cd mobile`, then `flutter analyze` and `flutter test` when Flutter tooling is available.
- Use PostgreSQL integration tests for persistence and concurrency invariants, and real Spring Security/JWT tests for authorization. Distinguish repository claims from independently verified results.

## Git workflow

- Use a task-specific branch. Before work, check `git status`, current branch and recent history; do not switch branches or discard changes without an explicit need and safe handling.
- Keep changes small and reviewable. Inspect `git diff`, `git diff --check` and test results before requesting review or permission to commit.
- Never rewrite historical migrations. Respect staged and unstaged user changes.

## Golden Path and deadline

The academic Golden Path is: road routing and immutable Quote; Booking with idempotent Quote consumption; spatial driver search and sequential offers; atomic driver acceptance; Trip state and realtime GPS; authorized customer tracking; cash completion; commission settlement, ratings and history.

Target completion date: November 22, 2026. Academic development and demonstration cost target: 0 VND. Prioritize a working end-to-end flow over optional features.
