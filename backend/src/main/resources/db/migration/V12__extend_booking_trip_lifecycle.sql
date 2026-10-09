ALTER TABLE bookings DROP CONSTRAINT chk_bookings_dispatch_status;
ALTER TABLE bookings DROP CONSTRAINT chk_bookings_assignment_state;

ALTER TABLE bookings
    ADD COLUMN driver_arrived_at TIMESTAMPTZ,
    ADD COLUMN passenger_onboard_at TIMESTAMPTZ,
    ADD COLUMN trip_started_at TIMESTAMPTZ,
    ADD COLUMN trip_completed_at TIMESTAMPTZ,
    ADD COLUMN driver_released_at TIMESTAMPTZ;

ALTER TABLE bookings ADD CONSTRAINT chk_bookings_trip_status CHECK (status IN (
    'REQUESTED', 'SEARCHING_DRIVER', 'DRIVER_ACCEPTED', 'DRIVER_ARRIVED',
    'PASSENGER_ONBOARD', 'IN_PROGRESS', 'COMPLETED'
));

ALTER TABLE bookings ADD CONSTRAINT chk_bookings_assignment_state CHECK (
    (status IN ('REQUESTED', 'SEARCHING_DRIVER') AND assigned_driver_id IS NULL
        AND assigned_vehicle_id IS NULL AND driver_accepted_at IS NULL)
    OR (status IN ('DRIVER_ACCEPTED', 'DRIVER_ARRIVED', 'PASSENGER_ONBOARD',
                   'IN_PROGRESS', 'COMPLETED') AND assigned_driver_id IS NOT NULL
        AND assigned_vehicle_id IS NOT NULL AND driver_accepted_at IS NOT NULL)
);

ALTER TABLE bookings ADD CONSTRAINT chk_bookings_trip_timestamps CHECK (
    (driver_arrived_at IS NOT NULL) = (status IN ('DRIVER_ARRIVED', 'PASSENGER_ONBOARD', 'IN_PROGRESS', 'COMPLETED'))
    AND (passenger_onboard_at IS NOT NULL) = (status IN ('PASSENGER_ONBOARD', 'IN_PROGRESS', 'COMPLETED'))
    AND (trip_started_at IS NOT NULL) = (status IN ('IN_PROGRESS', 'COMPLETED'))
    AND (trip_completed_at IS NOT NULL) = (status = 'COMPLETED')
    AND (driver_arrived_at IS NULL OR driver_arrived_at >= driver_accepted_at)
    AND (passenger_onboard_at IS NULL OR passenger_onboard_at >= driver_arrived_at)
    AND (trip_started_at IS NULL OR trip_started_at >= passenger_onboard_at)
    AND (trip_completed_at IS NULL OR trip_completed_at >= trip_started_at)
    AND (driver_released_at IS NULL OR (status = 'COMPLETED' AND driver_released_at >= trip_completed_at))
);

DROP INDEX uq_bookings_active_driver;
CREATE UNIQUE INDEX uq_bookings_active_driver ON bookings (assigned_driver_id)
    WHERE assigned_driver_id IS NOT NULL AND driver_released_at IS NULL;
