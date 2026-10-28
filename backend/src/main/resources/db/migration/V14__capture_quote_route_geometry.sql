-- Historical Quotes have no route geometry. Their authorized route reads report UNAVAILABLE.
ALTER TABLE quotes ADD COLUMN route_geometry JSONB;

ALTER TABLE quotes ADD CONSTRAINT chk_quotes_route_geometry_shape CHECK (
    CASE
        WHEN route_geometry IS NULL THEN TRUE
        WHEN jsonb_typeof(route_geometry) IS DISTINCT FROM 'object' THEN FALSE
        WHEN route_geometry->>'type' IS DISTINCT FROM 'LineString' THEN FALSE
        WHEN jsonb_typeof(route_geometry->'coordinates') IS DISTINCT FROM 'array' THEN FALSE
        ELSE jsonb_array_length(route_geometry->'coordinates') BETWEEN 2 AND 8192
            AND octet_length(route_geometry::text) <= 524288
    END
);

CREATE FUNCTION prevent_quote_route_geometry_update() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.route_geometry IS DISTINCT FROM NEW.route_geometry THEN
        RAISE EXCEPTION 'Quote route geometry is immutable';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_quotes_route_geometry_immutable
BEFORE UPDATE OF route_geometry ON quotes
FOR EACH ROW EXECUTE FUNCTION prevent_quote_route_geometry_update();
