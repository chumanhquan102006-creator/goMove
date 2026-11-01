ALTER TABLE bookings DROP CONSTRAINT chk_bookings_trip_status;
ALTER TABLE bookings DROP CONSTRAINT chk_bookings_assignment_state;
ALTER TABLE bookings DROP CONSTRAINT chk_bookings_trip_timestamps;

ALTER TABLE bookings
    ADD COLUMN cancelled_at TIMESTAMPTZ,
    ADD COLUMN cancelled_by VARCHAR(16),
    ADD COLUMN dispatch_failed_at TIMESTAMPTZ,
    ADD COLUMN dispatch_deadline_at TIMESTAMPTZ;

ALTER TABLE bookings ADD CONSTRAINT chk_bookings_trip_status CHECK (status IN (
    'REQUESTED', 'SEARCHING_DRIVER', 'DRIVER_ACCEPTED', 'DRIVER_ARRIVED',
    'PASSENGER_ONBOARD', 'IN_PROGRESS', 'COMPLETED', 'CANCELLED', 'NO_DRIVER_AVAILABLE'
));

ALTER TABLE bookings ADD CONSTRAINT chk_bookings_assignment_state CHECK (
    (status IN ('REQUESTED', 'SEARCHING_DRIVER', 'NO_DRIVER_AVAILABLE')
        AND assigned_driver_id IS NULL AND assigned_vehicle_id IS NULL
        AND driver_accepted_at IS NULL AND driver_released_at IS NULL)
    OR (status IN ('DRIVER_ACCEPTED', 'DRIVER_ARRIVED', 'PASSENGER_ONBOARD', 'IN_PROGRESS')
        AND assigned_driver_id IS NOT NULL AND assigned_vehicle_id IS NOT NULL
        AND driver_accepted_at IS NOT NULL AND driver_released_at IS NULL)
    OR (status = 'COMPLETED' AND assigned_driver_id IS NOT NULL
        AND assigned_vehicle_id IS NOT NULL AND driver_accepted_at IS NOT NULL)
    OR (status = 'CANCELLED' AND (
        (assigned_driver_id IS NULL AND assigned_vehicle_id IS NULL
            AND driver_accepted_at IS NULL AND driver_arrived_at IS NULL
            AND driver_released_at IS NULL)
        OR (assigned_driver_id IS NOT NULL AND assigned_vehicle_id IS NOT NULL
            AND driver_accepted_at IS NOT NULL AND driver_released_at IS NOT NULL)))
);

ALTER TABLE bookings ADD CONSTRAINT chk_bookings_trip_timestamps CHECK (
    (status = 'CANCELLED' OR
        (driver_arrived_at IS NOT NULL) =
            (status IN ('DRIVER_ARRIVED', 'PASSENGER_ONBOARD', 'IN_PROGRESS', 'COMPLETED')))
    AND (passenger_onboard_at IS NOT NULL) =
        (status IN ('PASSENGER_ONBOARD', 'IN_PROGRESS', 'COMPLETED'))
    AND (trip_started_at IS NOT NULL) = (status IN ('IN_PROGRESS', 'COMPLETED'))
    AND (trip_completed_at IS NOT NULL) = (status = 'COMPLETED')
    AND (status <> 'CANCELLED' OR (passenger_onboard_at IS NULL
        AND trip_started_at IS NULL AND trip_completed_at IS NULL))
    AND (driver_arrived_at IS NULL OR driver_arrived_at >= driver_accepted_at)
    AND (passenger_onboard_at IS NULL OR passenger_onboard_at >= driver_arrived_at)
    AND (trip_started_at IS NULL OR trip_started_at >= passenger_onboard_at)
    AND (trip_completed_at IS NULL OR trip_completed_at >= trip_started_at)
    AND (driver_released_at IS NULL OR
        (status = 'COMPLETED' AND driver_released_at >= trip_completed_at) OR
        (status = 'CANCELLED' AND driver_released_at >= cancelled_at))
);

ALTER TABLE bookings ADD CONSTRAINT chk_bookings_terminal_metadata CHECK (
    (status = 'CANCELLED' AND cancelled_at IS NOT NULL
        AND cancelled_at >= created_at AND cancelled_by IN ('CUSTOMER', 'DRIVER')
        AND dispatch_failed_at IS NULL
        AND (cancelled_by <> 'DRIVER' OR assigned_driver_id IS NOT NULL))
    OR (status = 'NO_DRIVER_AVAILABLE' AND dispatch_failed_at IS NOT NULL
        AND dispatch_failed_at >= created_at AND cancelled_at IS NULL AND cancelled_by IS NULL)
    OR (status NOT IN ('CANCELLED', 'NO_DRIVER_AVAILABLE')
        AND cancelled_at IS NULL AND cancelled_by IS NULL AND dispatch_failed_at IS NULL)
);

ALTER TABLE booking_driver_offers DROP CONSTRAINT booking_driver_offers_status_check;
ALTER TABLE booking_driver_offers ADD CONSTRAINT chk_offer_status CHECK (
    status IN ('PENDING', 'ACCEPTED', 'REJECTED', 'EXPIRED', 'CANCELLED')
);
