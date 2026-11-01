ALTER TABLE cash_payments DROP CONSTRAINT cash_payments_status_check;
ALTER TABLE cash_payments ADD CONSTRAINT cash_payments_status_check
    CHECK (status IN ('PENDING', 'PAID', 'VOID'));
ALTER TABLE cash_payments DROP CONSTRAINT chk_cash_payment_confirmation;
ALTER TABLE cash_payments ADD CONSTRAINT chk_cash_payment_confirmation CHECK (
    (status IN ('PENDING', 'VOID') AND collected_by_driver_id IS NULL AND paid_at IS NULL)
    OR (status = 'PAID' AND collected_by_driver_id IS NOT NULL AND paid_at IS NOT NULL)
);

CREATE OR REPLACE FUNCTION enforce_cash_payment_booking() RETURNS trigger AS $$
DECLARE accepted_fare NUMERIC(15,2);
DECLARE accepted_currency VARCHAR(3);
DECLARE booking_state VARCHAR(24);
DECLARE completed_at TIMESTAMPTZ;
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Cash payment cannot be deleted';
    END IF;
    IF TG_OP = 'UPDATE' AND
       (OLD.status IN ('PAID', 'VOID') OR NEW.public_id IS DISTINCT FROM OLD.public_id
        OR NEW.booking_id IS DISTINCT FROM OLD.booking_id
        OR NEW.method IS DISTINCT FROM OLD.method
        OR NEW.amount IS DISTINCT FROM OLD.amount
        OR NEW.currency_code IS DISTINCT FROM OLD.currency_code
        OR NEW.created_at IS DISTINCT FROM OLD.created_at
        OR (NEW.status = 'VOID' AND OLD.status <> 'PENDING')) THEN
        RAISE EXCEPTION 'Cash payment identity and accepted amount are immutable';
    END IF;
    SELECT final_fare, currency_code, status, trip_completed_at
      INTO accepted_fare, accepted_currency, booking_state, completed_at
      FROM bookings WHERE id = NEW.booking_id;
    IF NEW.amount IS DISTINCT FROM accepted_fare OR NEW.currency_code IS DISTINCT FROM accepted_currency THEN
        RAISE EXCEPTION 'Cash payment must equal accepted Booking fare and currency';
    END IF;
    IF NEW.status = 'PAID' AND
       (booking_state IS DISTINCT FROM 'COMPLETED' OR NEW.paid_at < completed_at) THEN
        RAISE EXCEPTION 'Cash payment requires completed Booking and ordered timestamp';
    END IF;
    IF NEW.status = 'VOID' AND booking_state NOT IN ('CANCELLED', 'NO_DRIVER_AVAILABLE') THEN
        RAISE EXCEPTION 'Void cash payment requires an uncollected terminal Booking';
    END IF;
    IF NEW.status = 'PENDING' AND booking_state IN ('CANCELLED', 'NO_DRIVER_AVAILABLE') THEN
        RAISE EXCEPTION 'Uncollected terminal Booking cannot have pending cash';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

UPDATE cash_payments p SET status = 'VOID', updated_at = CURRENT_TIMESTAMP, version = p.version + 1
FROM bookings b WHERE p.booking_id = b.id AND p.status = 'PENDING'
    AND b.status IN ('CANCELLED', 'NO_DRIVER_AVAILABLE');

CREATE OR REPLACE FUNCTION void_uncollected_cash() RETURNS trigger AS $$
BEGIN
    IF NEW.status IN ('CANCELLED', 'NO_DRIVER_AVAILABLE') AND OLD.status IS DISTINCT FROM NEW.status THEN
        UPDATE cash_payments SET status = 'VOID', updated_at = CURRENT_TIMESTAMP, version = version + 1
        WHERE booking_id = NEW.id AND status = 'PENDING';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_void_uncollected_cash AFTER UPDATE OF status ON bookings
    FOR EACH ROW EXECUTE FUNCTION void_uncollected_cash();

CREATE TABLE admin_action_audit (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    admin_user_public_id UUID NOT NULL REFERENCES users(public_id),
    target_public_id UUID NOT NULL REFERENCES drivers(public_id),
    action_type VARCHAR(40) NOT NULL CHECK (action_type = 'DRIVER_APPROVAL_STATUS'),
    previous_status VARCHAR(20) NOT NULL,
    new_status VARCHAR(20) NOT NULL,
    outcome VARCHAR(20) NOT NULL CHECK (outcome IN ('APPLIED', 'UNCHANGED')),
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE OR REPLACE FUNCTION reject_admin_audit_mutation() RETURNS trigger AS $$
BEGIN
    RAISE EXCEPTION 'Admin action audit is append-only';
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_admin_audit_immutable BEFORE UPDATE OR DELETE ON admin_action_audit
    FOR EACH ROW EXECUTE FUNCTION reject_admin_audit_mutation();
CREATE INDEX idx_admin_action_audit_target_time ON admin_action_audit (target_public_id, occurred_at DESC);
CREATE INDEX idx_admin_action_audit_admin_time ON admin_action_audit (admin_user_public_id, occurred_at DESC);

CREATE INDEX idx_drivers_approval_created ON drivers (approval_status, created_at DESC, id DESC);
CREATE INDEX idx_users_role_created ON users (role, created_at DESC, id DESC);
CREATE INDEX idx_bookings_status_created ON bookings (status, created_at DESC, id DESC);
CREATE INDEX idx_bookings_customer_activity ON bookings (customer_id, created_at DESC);
CREATE INDEX idx_bookings_driver_activity ON bookings (assigned_driver_id, created_at DESC)
    WHERE assigned_driver_id IS NOT NULL;
CREATE INDEX idx_cash_payments_status_booking ON cash_payments (status, booking_id);
