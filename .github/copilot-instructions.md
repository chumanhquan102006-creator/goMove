# GoMove Copilot Instructions

Before making changes, read the repository-root `AGENTS.md` and follow it together with the user's request. Treat the existing source, migrations, tests and build files as authoritative; do not assume unimplemented modules exist.

GoMove has a Java 21 / Spring Boot 3.5.16 modular-monolith backend in `backend/` and a Flutter/BLoC app in `mobile/`. Keep module boundaries and change only the area authorized by the task.

Key invariants:

- Use authenticated JWT/SecurityContext identity, public UUIDs in APIs, role checks and resource ownership. Never trust client-supplied user IDs or roles; never expose internal IDs, secrets or password hashes; return access/refresh tokens only through intended authentication endpoints and never log them.
- Add new Flyway migrations instead of editing existing ones. Use PostgreSQL/PostGIS integration tests, `GEOGRAPHY(Point,4326)`, longitude/latitude coordinate order and meters for spatial distances.
- Use `BigDecimal` and PostgreSQL `NUMERIC` for money. Keep Quote snapshots immutable, the 60-second expiry boundary exclusive, and all displayed fare components reconciled exactly to `finalFare`.
- Keep external HTTP calls outside database transactions. Make Booking idempotency, Quote consumption, dispatch assignment and other concurrent state changes database-backed and atomic when implementing those future modules.
- Preserve existing authentication, refresh-token, driver-state and API-response conventions. Avoid unrelated refactors, unnecessary infrastructure and unapproved paid dependencies.

Run the relevant real tests before reporting completion: backend `./mvnw clean test` (Windows `mvnw.cmd clean test`); mobile `flutter analyze` and `flutter test` when available. Report actual results and limitations; never claim a test passed without terminal evidence.

These repository instructions describe expected behavior; they do not create or invoke agents, subagents, skills or MCP configurations.
