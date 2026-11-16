CREATE INDEX idx_bookings_m2b_open_pickup_gist
    ON bookings USING GIST (pickup_location)
    WHERE status IN ('REQUESTED', 'SEARCHING_DRIVER')
      AND assigned_driver_id IS NULL
      AND assigned_vehicle_id IS NULL;
