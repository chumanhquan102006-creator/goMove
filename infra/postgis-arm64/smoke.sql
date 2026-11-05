\set ON_ERROR_STOP on

CREATE EXTENSION postgis;

SELECT current_setting('server_version') AS postgres_version,
       postgis_full_version() AS postgis_version;

CREATE TEMP TABLE spatial_probe (
    location GEOGRAPHY(Point,4326) NOT NULL
);
CREATE INDEX spatial_probe_location_gist ON spatial_probe USING GIST (location);
INSERT INTO spatial_probe(location)
VALUES (ST_SetSRID(ST_MakePoint(105.8524, 21.0287), 4326)::geography);

DO $$
DECLARE
    distance_meters DOUBLE PRECISION;
BEGIN
    IF current_setting('server_version_num')::INTEGER / 10000 <> 16 THEN
        RAISE EXCEPTION 'Expected PostgreSQL 16';
    END IF;
    IF (SELECT extversion FROM pg_extension WHERE extname = 'postgis') NOT LIKE '3.5.%' THEN
        RAISE EXCEPTION 'Expected PostGIS 3.5';
    END IF;

    SELECT ST_Distance(location, 'SRID=4326;POINT(105.8576 21.0245)'::geography)
    INTO distance_meters FROM spatial_probe;
    IF distance_meters NOT BETWEEN 700 AND 800 THEN
        RAISE EXCEPTION 'Unexpected geography distance: %', distance_meters;
    END IF;
    IF (SELECT COUNT(*) FROM spatial_probe
        WHERE ST_DWithin(location, 'SRID=4326;POINT(105.8576 21.0245)'::geography, 1000)) <> 1 THEN
        RAISE EXCEPTION 'Spatial radius query failed';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE tablename = 'spatial_probe' AND indexname = 'spatial_probe_location_gist'
          AND indexdef ILIKE '%USING gist%'
    ) THEN
        RAISE EXCEPTION 'GiST index missing';
    END IF;
END $$;
