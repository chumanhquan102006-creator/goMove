CREATE TABLE cash_payments (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    public_id UUID NOT NULL UNIQUE,
    booking_id BIGINT NOT NULL UNIQUE REFERENCES bookings(id),
    method VARCHAR(12) NOT NULL DEFAULT 'CASH' CHECK (method = 'CASH'),
    status VARCHAR(12) NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'PAID')),
    amount NUMERIC(15,2) NOT NULL CHECK (amount > 0),
    currency_code VARCHAR(3) NOT NULL CHECK (currency_code = 'VND'),
    collected_by_driver_id BIGINT REFERENCES drivers(id),
    paid_at TIMESTAMPTZ,
    version BIGINT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_cash_payment_confirmation CHECK (
        (status = 'PENDING' AND collected_by_driver_id IS NULL AND paid_at IS NULL)
        OR (status = 'PAID' AND collected_by_driver_id IS NOT NULL AND paid_at IS NOT NULL)
    )
);

-- A nullable composite FK permits PENDING rows but requires a PAID collector to
-- match the Booking's recorded assigned driver. Keep the historical assignment.
ALTER TABLE bookings ADD CONSTRAINT uq_bookings_id_assigned_driver UNIQUE (id, assigned_driver_id);
ALTER TABLE cash_payments ADD CONSTRAINT fk_cash_payment_assigned_collector
    FOREIGN KEY (booking_id, collected_by_driver_id)
    REFERENCES bookings(id, assigned_driver_id);

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
       (OLD.status = 'PAID' OR NEW.public_id IS DISTINCT FROM OLD.public_id
        OR NEW.booking_id IS DISTINCT FROM OLD.booking_id
        OR NEW.method IS DISTINCT FROM OLD.method
        OR NEW.amount IS DISTINCT FROM OLD.amount
        OR NEW.currency_code IS DISTINCT FROM OLD.currency_code
        OR NEW.created_at IS DISTINCT FROM OLD.created_at) THEN
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
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_cash_payment_booking BEFORE INSERT OR UPDATE OR DELETE ON cash_payments
    FOR EACH ROW EXECUTE FUNCTION enforce_cash_payment_booking();

-- V13 does not infer cash collection from historical trip completion.
INSERT INTO cash_payments (public_id, booking_id, method, status, amount, currency_code)
SELECT gen_random_uuid(), id, 'CASH', 'PENDING', final_fare, currency_code FROM bookings;

CREATE TABLE driver_commission_ledger (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    public_id UUID NOT NULL UNIQUE,
    booking_id BIGINT NOT NULL REFERENCES bookings(id),
    driver_id BIGINT NOT NULL REFERENCES drivers(id),
    event_type VARCHAR(32) NOT NULL CHECK (event_type = 'COMMISSION_ACCRUED'),
    currency_code VARCHAR(3) NOT NULL CHECK (currency_code = 'VND'),
    gross_cash_fare NUMERIC(15,2) NOT NULL CHECK (gross_cash_fare > 0),
    commission_rate NUMERIC(12,10) NOT NULL CHECK (commission_rate BETWEEN 0 AND 1),
    commission_amount NUMERIC(15,2) NOT NULL CHECK (
        commission_amount >= 0 AND commission_amount <= gross_cash_fare
        AND commission_amount = ROUND(gross_cash_fare * commission_rate, 0)
    ),
    commission_policy_version VARCHAR(40) NOT NULL CHECK (length(commission_policy_version) > 0),
    occurred_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_commission_ledger_booking_event UNIQUE (booking_id, event_type),
    CONSTRAINT fk_commission_ledger_assigned_driver FOREIGN KEY (booking_id, driver_id)
        REFERENCES bookings(id, assigned_driver_id)
);
CREATE INDEX idx_commission_ledger_driver ON driver_commission_ledger (driver_id);

CREATE OR REPLACE FUNCTION enforce_commission_ledger_booking() RETURNS trigger AS $$
DECLARE accepted_fare NUMERIC(15,2);
DECLARE accepted_currency VARCHAR(3);
DECLARE booking_state VARCHAR(24);
DECLARE completed_at TIMESTAMPTZ;
BEGIN
    SELECT final_fare, currency_code, status, trip_completed_at
      INTO accepted_fare, accepted_currency, booking_state, completed_at
      FROM bookings WHERE id = NEW.booking_id;
    IF NEW.gross_cash_fare IS DISTINCT FROM accepted_fare
       OR NEW.currency_code IS DISTINCT FROM accepted_currency
       OR booking_state IS DISTINCT FROM 'COMPLETED'
       OR completed_at IS NULL OR NEW.occurred_at < completed_at THEN
        RAISE EXCEPTION 'Commission accrual must match the completed Booking';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_commission_ledger_booking BEFORE INSERT ON driver_commission_ledger
    FOR EACH ROW EXECUTE FUNCTION enforce_commission_ledger_booking();

CREATE OR REPLACE FUNCTION reject_commission_ledger_mutation() RETURNS trigger AS $$
BEGIN
    RAISE EXCEPTION 'Commission ledger is append-only';
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_commission_ledger_immutable BEFORE UPDATE OR DELETE ON driver_commission_ledger
    FOR EACH ROW EXECUTE FUNCTION reject_commission_ledger_mutation();
