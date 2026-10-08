CREATE TABLE driver_locations (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    driver_id BIGINT NOT NULL,
    current_location GEOGRAPHY(Point, 4326) NOT NULL,
    accuracy DOUBLE PRECISION,
    bearing DOUBLE PRECISION,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL,
    version BIGINT NOT NULL DEFAULT 0,
    CONSTRAINT fk_driver_locations_driver
        FOREIGN KEY (driver_id) REFERENCES drivers(id) ON DELETE CASCADE,
    CONSTRAINT uq_driver_locations_driver_id UNIQUE (driver_id),
    CONSTRAINT chk_driver_locations_accuracy
        CHECK (accuracy IS NULL OR accuracy >= 0),
    CONSTRAINT chk_driver_locations_bearing
        CHECK (bearing IS NULL OR (bearing >= 0 AND bearing < 360))
);

CREATE INDEX idx_driver_locations_current_location_gist
    ON driver_locations
    USING GIST (current_location);
