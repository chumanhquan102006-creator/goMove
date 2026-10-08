CREATE TABLE quotes (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    public_id UUID NOT NULL UNIQUE,
    customer_id BIGINT NOT NULL REFERENCES users(id),
    pickup_location GEOGRAPHY(Point,4326) NOT NULL,
    dropoff_location GEOGRAPHY(Point,4326) NOT NULL,
    distance_meters NUMERIC(15,3) NOT NULL CHECK (distance_meters > 0),
    duration_seconds NUMERIC(15,3) NOT NULL CHECK (duration_seconds > 0),
    routing_provider VARCHAR(40) NOT NULL,
    vehicle_type VARCHAR(20) NOT NULL CHECK (vehicle_type IN ('MOTORBIKE', 'CAR_4_SEAT', 'CAR_7_SEAT')),
    currency_code VARCHAR(3) NOT NULL CHECK (currency_code = 'VND'),
    base_fare NUMERIC(15,2) NOT NULL CHECK (base_fare >= 0),
    distance_fare NUMERIC(15,2) NOT NULL CHECK (distance_fare >= 0),
    time_fare NUMERIC(15,2) NOT NULL CHECK (time_fare >= 0),
    surcharge NUMERIC(15,2) NOT NULL CHECK (surcharge >= 0),
    surge_multiplier NUMERIC(8,4) NOT NULL CHECK (surge_multiplier > 0),
    surge_amount NUMERIC(15,2) NOT NULL,
    discount_amount NUMERIC(15,2) NOT NULL CHECK (discount_amount >= 0),
    rounding_adjustment NUMERIC(15,2) NOT NULL,
    final_fare NUMERIC(15,2) NOT NULL CHECK (final_fare > 0),
    pricing_engine_version VARCHAR(30) NOT NULL,
    pricing_snapshot JSONB NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'ISSUED' CHECK (status IN ('ISSUED', 'CONSUMED', 'EXPIRED')),
    issued_at TIMESTAMP WITH TIME ZONE NOT NULL,
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    consumed_at TIMESTAMP WITH TIME ZONE,
    version BIGINT NOT NULL DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_quotes_expiry CHECK (expires_at > issued_at),
    CONSTRAINT chk_quotes_fare_reconciliation CHECK (
        final_fare = base_fare + distance_fare + time_fare + surcharge
            + surge_amount - discount_amount + rounding_adjustment
    ),
    CONSTRAINT chk_quotes_consumption CHECK (
        (status = 'CONSUMED' AND consumed_at IS NOT NULL)
        OR (status <> 'CONSUMED' AND consumed_at IS NULL)
    )
);

CREATE INDEX idx_quotes_customer_issued_at ON quotes (customer_id, issued_at DESC);
