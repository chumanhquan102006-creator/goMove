CREATE TABLE drivers (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id BIGINT NOT NULL UNIQUE REFERENCES users(id),
    public_id UUID NOT NULL UNIQUE,
    license_number VARCHAR(50) NOT NULL UNIQUE,
    approval_status VARCHAR(20) NOT NULL DEFAULT 'PENDING'
        CHECK (approval_status IN ('PENDING', 'APPROVED', 'REJECTED', 'SUSPENDED')),
    operating_status VARCHAR(20) NOT NULL DEFAULT 'OFFLINE'
        CHECK (operating_status IN ('OFFLINE', 'ONLINE', 'BUSY')),
    rating_average NUMERIC(3,2) NOT NULL DEFAULT 5.00,
    total_trips INT NOT NULL DEFAULT 0,
    version BIGINT NOT NULL DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_drivers_user_id ON drivers (user_id);
CREATE INDEX idx_drivers_public_id ON drivers (public_id);
CREATE INDEX idx_drivers_license_number ON drivers (license_number);
