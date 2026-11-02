-- Ratings and GoPoints are independent of CASH and commission accounting.
ALTER TABLE bookings ADD CONSTRAINT uq_bookings_id_customer UNIQUE (id, customer_id);

CREATE TABLE trip_ratings (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    public_id UUID NOT NULL UNIQUE,
    booking_id BIGINT NOT NULL UNIQUE REFERENCES bookings(id),
    customer_id BIGINT NOT NULL REFERENCES users(id),
    driver_id BIGINT NOT NULL REFERENCES drivers(id),
    stars SMALLINT NOT NULL CHECK (stars BETWEEN 1 AND 5),
    comment VARCHAR(500),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_trip_ratings_id_driver UNIQUE (id, driver_id),
    CONSTRAINT fk_trip_ratings_customer_booking FOREIGN KEY (booking_id, customer_id)
        REFERENCES bookings(id, customer_id),
    CONSTRAINT fk_trip_ratings_driver_booking FOREIGN KEY (booking_id, driver_id)
        REFERENCES bookings(id, assigned_driver_id)
);
CREATE INDEX idx_trip_ratings_driver_recent ON trip_ratings (driver_id, created_at DESC, id DESC);

CREATE OR REPLACE FUNCTION guard_trip_rating() RETURNS trigger AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'Trip ratings are immutable';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM bookings WHERE id = NEW.booking_id AND status = 'COMPLETED') THEN
        RAISE EXCEPTION 'Rating requires a completed Booking';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_trip_rating_guard BEFORE INSERT OR UPDATE OR DELETE ON trip_ratings
    FOR EACH ROW EXECUTE FUNCTION guard_trip_rating();

CREATE TABLE driver_point_events (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    public_id UUID NOT NULL UNIQUE,
    rating_id BIGINT NOT NULL UNIQUE REFERENCES trip_ratings(id),
    driver_id BIGINT NOT NULL REFERENCES drivers(id),
    event_type VARCHAR(24) NOT NULL CHECK (event_type = 'RATING_REWARD'),
    points_delta SMALLINT NOT NULL CHECK (points_delta IN (-10, -5, 0, 5, 10)),
    policy_version VARCHAR(32) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_point_event_rating_driver FOREIGN KEY (rating_id, driver_id)
        REFERENCES trip_ratings(id, driver_id)
);
CREATE INDEX idx_driver_point_events_driver_recent ON driver_point_events (driver_id, created_at DESC, id DESC);

CREATE OR REPLACE FUNCTION guard_point_event() RETURNS trigger AS $$
DECLARE rating_stars SMALLINT;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'GoPoints events are immutable';
    END IF;
    SELECT stars INTO rating_stars FROM trip_ratings WHERE id = NEW.rating_id;
    IF rating_stars IS NULL OR NOT (
        (rating_stars = 5 AND NEW.points_delta = 10) OR
        (rating_stars = 4 AND NEW.points_delta = 5) OR
        (rating_stars = 3 AND NEW.points_delta = 0) OR
        (rating_stars = 2 AND NEW.points_delta = -5) OR
        (rating_stars = 1 AND NEW.points_delta = -10)) THEN
        RAISE EXCEPTION 'GoPoints must match the verified rating';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_point_event_guard BEFORE INSERT OR UPDATE OR DELETE ON driver_point_events
    FOR EACH ROW EXECUTE FUNCTION guard_point_event();

CREATE TABLE driver_quality_cases (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    public_id UUID NOT NULL UNIQUE,
    driver_id BIGINT NOT NULL REFERENCES drivers(id),
    status VARCHAR(16) NOT NULL DEFAULT 'OPEN'
        CHECK (status IN ('OPEN', 'WARNED', 'DISPUTED', 'SUSPENDED', 'DISMISSED')),
    rating_count INTEGER NOT NULL CHECK (rating_count > 0),
    recent_average NUMERIC(3,2) NOT NULL CHECK (recent_average BETWEEN 1 AND 5),
    reason VARCHAR(500) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE UNIQUE INDEX uq_driver_quality_active_case ON driver_quality_cases (driver_id)
    WHERE status IN ('OPEN', 'WARNED', 'DISPUTED', 'SUSPENDED');
CREATE INDEX idx_driver_quality_cases_status_recent ON driver_quality_cases (status, created_at DESC, id DESC);

CREATE TABLE driver_quality_case_actions (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    public_id UUID NOT NULL UNIQUE,
    case_id BIGINT NOT NULL REFERENCES driver_quality_cases(id),
    actor_user_id BIGINT NOT NULL REFERENCES users(id),
    action VARCHAR(16) NOT NULL CHECK (action IN ('WARN', 'SUSPEND', 'DISMISS', 'DISPUTE')),
    note VARCHAR(500),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_quality_actions_case_time ON driver_quality_case_actions (case_id, created_at DESC, id DESC);
CREATE OR REPLACE FUNCTION reject_quality_action_mutation() RETURNS trigger AS $$
BEGIN
    RAISE EXCEPTION 'Quality case actions are append-only';
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_quality_action_immutable BEFORE UPDATE OR DELETE ON driver_quality_case_actions
    FOR EACH ROW EXECUTE FUNCTION reject_quality_action_mutation();
