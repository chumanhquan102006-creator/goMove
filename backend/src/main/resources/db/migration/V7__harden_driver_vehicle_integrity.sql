CREATE UNIQUE INDEX ux_vehicles_one_active_per_driver
    ON vehicles (driver_id)
    WHERE is_active = TRUE;

ALTER TABLE drivers
    ADD CONSTRAINT chk_drivers_operating_requires_approved
        CHECK (operating_status = 'OFFLINE' OR approval_status = 'APPROVED'),
    ADD CONSTRAINT chk_drivers_rating_average_range
        CHECK (rating_average >= 0.00 AND rating_average <= 5.00),
    ADD CONSTRAINT chk_drivers_total_trips_non_negative
        CHECK (total_trips >= 0);
