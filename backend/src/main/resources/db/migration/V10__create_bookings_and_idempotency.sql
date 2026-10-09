CREATE TABLE bookings (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    public_id UUID NOT NULL UNIQUE,
    customer_id BIGINT NOT NULL REFERENCES users(id),
    quote_id BIGINT NOT NULL REFERENCES quotes(id),
    status VARCHAR(24) NOT NULL CHECK (status IN ('REQUESTED')),
    pickup_location GEOGRAPHY(Point,4326) NOT NULL,
    dropoff_location GEOGRAPHY(Point,4326) NOT NULL,
    distance_meters NUMERIC(15,3) NOT NULL CHECK (distance_meters > 0),
    duration_seconds NUMERIC(15,3) NOT NULL CHECK (duration_seconds > 0),
    routing_provider VARCHAR(40) NOT NULL,
    vehicle_type VARCHAR(20) NOT NULL CHECK (vehicle_type IN ('MOTORBIKE', 'CAR_4_SEAT', 'CAR_7_SEAT')),
    currency_code VARCHAR(3) NOT NULL CHECK (currency_code = 'VND'),
    final_fare NUMERIC(15,2) NOT NULL CHECK (final_fare > 0),
    pricing_engine_version VARCHAR(30) NOT NULL,
    pricing_snapshot JSONB NOT NULL,
    version BIGINT NOT NULL DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_bookings_quote_id UNIQUE (quote_id)
);

CREATE TABLE booking_idempotency (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id BIGINT NOT NULL REFERENCES users(id),
    idempotency_key VARCHAR(128) NOT NULL,
    request_hash VARCHAR(64) NOT NULL CHECK (request_hash ~ '^[0-9a-f]{64}$'),
    booking_id BIGINT REFERENCES bookings(id),
    http_status SMALLINT,
    response_body JSONB,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_booking_idempotency_customer_key UNIQUE (customer_id, idempotency_key),
    CONSTRAINT chk_booking_idempotency_outcome CHECK (
        (booking_id IS NULL AND http_status IS NULL AND response_body IS NULL)
        OR (booking_id IS NOT NULL AND http_status = 201 AND response_body IS NOT NULL)
    )
);
