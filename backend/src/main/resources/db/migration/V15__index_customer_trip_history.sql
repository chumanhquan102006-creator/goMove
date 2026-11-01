CREATE INDEX idx_bookings_customer_completed_history
    ON bookings (customer_id, trip_completed_at DESC, id DESC)
    WHERE status = 'COMPLETED';
