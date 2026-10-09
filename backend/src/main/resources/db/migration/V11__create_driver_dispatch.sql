ALTER TABLE bookings DROP CONSTRAINT bookings_status_check;
ALTER TABLE bookings ADD CONSTRAINT chk_bookings_dispatch_status
    CHECK (status IN ('REQUESTED', 'SEARCHING_DRIVER', 'DRIVER_ACCEPTED'));

ALTER TABLE bookings
    ADD COLUMN assigned_driver_id BIGINT REFERENCES drivers(id),
    ADD COLUMN assigned_vehicle_id BIGINT REFERENCES vehicles(id),
    ADD COLUMN driver_accepted_at TIMESTAMP WITH TIME ZONE,
    ADD COLUMN next_dispatch_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP;

ALTER TABLE bookings ADD CONSTRAINT chk_bookings_assignment_state CHECK (
    (status = 'DRIVER_ACCEPTED' AND assigned_driver_id IS NOT NULL
        AND assigned_vehicle_id IS NOT NULL AND driver_accepted_at IS NOT NULL)
    OR (status <> 'DRIVER_ACCEPTED' AND assigned_driver_id IS NULL
        AND assigned_vehicle_id IS NULL AND driver_accepted_at IS NULL)
);

ALTER TABLE vehicles ADD CONSTRAINT uq_vehicle_id_driver UNIQUE (id, driver_id);
ALTER TABLE bookings ADD CONSTRAINT fk_bookings_assigned_vehicle_driver
    FOREIGN KEY (assigned_vehicle_id, assigned_driver_id) REFERENCES vehicles (id, driver_id);

CREATE UNIQUE INDEX uq_bookings_active_driver
    ON bookings (assigned_driver_id) WHERE status = 'DRIVER_ACCEPTED';
CREATE INDEX idx_bookings_dispatch_due
    ON bookings (next_dispatch_at, id)
    WHERE status IN ('REQUESTED', 'SEARCHING_DRIVER');

CREATE TABLE booking_driver_offers (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    public_id UUID NOT NULL UNIQUE,
    booking_id BIGINT NOT NULL REFERENCES bookings(id),
    driver_id BIGINT NOT NULL REFERENCES drivers(id),
    vehicle_id BIGINT NOT NULL REFERENCES vehicles(id),
    status VARCHAR(16) NOT NULL CHECK (status IN ('PENDING', 'ACCEPTED', 'REJECTED', 'EXPIRED')),
    offered_at TIMESTAMP WITH TIME ZONE NOT NULL,
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    responded_at TIMESTAMP WITH TIME ZONE,
    version BIGINT NOT NULL DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_offer_exact_lease CHECK (expires_at = offered_at + INTERVAL '15 seconds'),
    CONSTRAINT chk_offer_response CHECK (
        (status = 'PENDING' AND responded_at IS NULL)
        OR (status <> 'PENDING' AND responded_at IS NOT NULL)
    ),
    CONSTRAINT fk_offer_vehicle_driver
        FOREIGN KEY (vehicle_id, driver_id) REFERENCES vehicles (id, driver_id),
    CONSTRAINT uq_offer_booking_driver UNIQUE (booking_id, driver_id)
);

CREATE UNIQUE INDEX uq_offer_pending_booking
    ON booking_driver_offers (booking_id) WHERE status = 'PENDING';
CREATE UNIQUE INDEX uq_offer_pending_driver
    ON booking_driver_offers (driver_id) WHERE status = 'PENDING';
CREATE UNIQUE INDEX uq_offer_accepted_booking
    ON booking_driver_offers (booking_id) WHERE status = 'ACCEPTED';
