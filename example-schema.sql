-- example schema, data and implementation of an on-line and off-line Kalman Filter in SQL

-- put everything in a separate schema
create schema kalman;

-- example table to store positional data + timestamps
create table kalman.positions (
                                  device_id bigint,
                                  datetime timestamptz,
                                  longitude double precision,
                                  latitude double precision,
                                  hdop double precision,
                                  filtered_longitude double precision,
                                  filtered_latitude double precision
);

create unique index positions_uq on kalman.positions (device_id, datetime);

create table kalman.devices (
                                id serial primary key,
                                current_state jsonb
);

-- kalman filter function
create function kalman.kalman_step(
    prev_lat double precision,
    prev_lon double precision,
    prev_P float8[][],           -- 2x2 previous covariance matrix
    curr_lat double precision,
    curr_lon double precision,
    prev_time timestamptz,
    curr_time timestamptz,
    hdop double precision,
    sigma_m double precision     -- standard deviation in meters (f.e. 3.0 or 5.0)
)
    returns table (
                      est_lat double precision,
                      est_lon double precision,
                      updated_P float8[][]
                  )
    as
$$
DECLARE
    F FLOAT8[2][2] := ARRAY[
        [1, 0],
        [0, 1]
        ];
    H FLOAT8[2][2] := ARRAY[
        [1, 0],
        [0, 1]
        ];
    R FLOAT8[2][2];
    Q FLOAT8[2][2];
    P FLOAT8[2][2];
    K FLOAT8[2][2];
    S FLOAT8[2][2];
    y FLOAT8[2];
    x_pred FLOAT8[2];
    x_prev FLOAT8[2];
    lat_cos DOUBLE PRECISION;
    sigma_lat DOUBLE PRECISION;
    sigma_lon DOUBLE PRECISION;
    delta_t DOUBLE PRECISION;
    process_sigma CONSTANT FLOAT8 := 0.00001; -- Prozessrauschen pro Sekunde (in Grad)
    dist FLOAT8;
BEGIN
    delta_t := EXTRACT(EPOCH FROM (curr_time - prev_time));
    -- ignore sub-second time differences
    IF delta_t < 1 THEN
        RETURN QUERY SELECT
                                            prev_lat,
                                            prev_lon,
                                            prev_P;
        RETURN;
    END IF;

    -- state vecor of the previous estimate
    x_prev := ARRAY[prev_lat, prev_lon];

    -- for lon/lat to m conversion
    lat_cos := COS(RADIANS(prev_lat));

    -- distance in meters (simple approximation)
    dist := sqrt(POWER((curr_lat - prev_lat) * 111320, 2)
        + POWER((curr_lon - prev_lon) * 111320 * lat_cos, 2));

    -- HDOP and Sigma in lon/lat degrees
    sigma_lat := (sigma_m * hdop) / 111320;
    sigma_lon := (sigma_m * hdop) / (111320 * lat_cos);

    -- base measurement noise covariance R
    R := ARRAY[
        [POWER(sigma_lat, 2), 0],
        [0, POWER(sigma_lon, 2)]
        ];

    -- process noise Q proportional to the time difference
    Q := ARRAY[
        [process_sigma * delta_t, 0],
        [0, process_sigma * delta_t]
        ];

    -- predict
    x_pred := x_prev;

    P := mat_add(
            mat_mult(
                    mat_mult(F, prev_P),
                    mat_transpose(F)
            ),
            Q
         );

    y[1] := curr_lat - x_pred[1];
    y[2] := curr_lon - x_pred[2];

    -- covariance S
    S := mat_add(
            mat_mult(
                    mat_mult(H, P),
                    mat_transpose(H)
            ),
            R
         );

    -- inverse of S
    BEGIN
        S := mat_inv2x2(S);
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Cannot invert covariance matrix "%".', S;
        RETURN QUERY SELECT
                         prev_lat,
                         prev_lon,
                         prev_P;
        RETURN;
    END;

    -- Kalman Gain
    K := mat_mult(
            mat_mult(P, mat_transpose(H)),
            S
         );

    -- state update
    x_pred[1] := x_pred[1] + K[1][1] * y[1] + K[1][2] * y[2];
    x_pred[2] := x_pred[2] + K[2][1] * y[1] + K[2][2] * y[2];

    -- update covariance matrix
    P := mat_mult(
            mat_sub(
                    mat_eye(2),
                    mat_mult(K, H)
            ),
            P
         );

    RETURN QUERY SELECT
                     x_pred[1],
                     x_pred[2],
                     P;
END;
$$ language plpgsql;

-- utility functions
-- multiply matrices
CREATE FUNCTION kalman.mat_mult(a FLOAT8[][], b FLOAT8[][])
    RETURNS FLOAT8[][] AS
$$
DECLARE
    rows INT := array_upper(a,1);
    cols INT := array_upper(b,2);
inner INT := array_upper(a,2);
    res FLOAT8[][];
    r INT;
    c INT;
    k INT;
BEGIN
    res := ARRAY(SELECT ARRAY(SELECT 0::FLOAT8 FROM generate_series(1,cols)) FROM generate_series(1,rows));
    FOR r IN 1..rows LOOP
        FOR c IN 1..cols LOOP
            res[r][c] := 0;
            FOR k IN 1.."inner" LOOP
                res[r][c] := res[r][c] + a[r][k]*b[k][c];
            END LOOP;
        END LOOP;
    END LOOP;
    RETURN res;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- matrix transpose
CREATE FUNCTION kalman.mat_transpose(a FLOAT8[][])
    RETURNS FLOAT8[][] AS
$$
DECLARE
rows INT := array_upper(a,1);
    cols INT := array_upper(a,2);
    res FLOAT8[][];
    r INT;
    c INT;
BEGIN
    res := ARRAY(SELECT ARRAY(SELECT 0::FLOAT8 FROM generate_series(1,rows)) FROM generate_series(1,cols));
    FOR r IN 1..rows LOOP
        FOR c IN 1..cols LOOP
                res[c][r] := a[r][c];
        END LOOP;
    END LOOP;
    RETURN res;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- matrix addition
CREATE FUNCTION kalman.mat_add(a FLOAT8[][], b FLOAT8[][])
    RETURNS FLOAT8[][] AS
$$
DECLARE
    rows INT := array_upper(a,1);
    cols INT := array_upper(a,2);
    res FLOAT8[][];
    r INT;
    c INT;
BEGIN
    res := ARRAY(SELECT ARRAY(SELECT 0::FLOAT8 FROM generate_series(1,cols)) FROM generate_series(1,rows));
    FOR r IN 1..rows LOOP
        FOR c IN 1..cols LOOP
                res[r][c] := a[r][c] + b[r][c];
        END LOOP;
    END LOOP;
    RETURN res;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- matrix subtraktion
CREATE FUNCTION kalman.mat_sub(a FLOAT8[][], b FLOAT8[][])
    RETURNS FLOAT8[][] AS
$$
DECLARE
    rows INT := array_upper(a,1);
    cols INT := array_upper(a,2);
    res FLOAT8[][];
    r INT;
    c INT;
BEGIN
    res := ARRAY(SELECT ARRAY(SELECT 0::FLOAT8 FROM generate_series(1,cols)) FROM generate_series(1,rows));
    FOR r IN 1..rows LOOP
        FOR c IN 1..cols LOOP
                res[r][c] := a[r][c] - b[r][c];
        END LOOP;
    END LOOP;
    RETURN res;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- 2x2 matrix inversion
CREATE FUNCTION kalman.mat_inv2x2(a FLOAT8[][])
    RETURNS FLOAT8[][] AS
$$
DECLARE
    det FLOAT8 := a[1][1]*a[2][2] - a[1][2]*a[2][1];
    res FLOAT8[2][2] := ARRAY[
        [0,0],
        [0,0]
        ];
BEGIN
    IF det = 0 THEN
        RAISE EXCEPTION 'Matrix cannot be inverted.';
    END IF;
        res[1][1] := a[2][2]/det;
        res[1][2] := -a[1][2]/det;
        res[2][1] := -a[2][1]/det;
        res[2][2] := a[1][1]/det;
    RETURN res;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- create eye matrix
CREATE FUNCTION kalman.mat_eye(n INT)
    RETURNS FLOAT8[][] AS
$$
DECLARE
res FLOAT8[][];
    r INT;
BEGIN
    res := ARRAY(SELECT ARRAY(SELECT 0::FLOAT8 FROM generate_series(1,n)) FROM generate_series(1,n));
    FOR r IN 1..n LOOP
                res[r][r] := 1;
    END LOOP;
    RETURN res;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- simple upsert function to insert or update positional data (assumes that data arrives in chronological order!)
create function kalman.upsert_position(in idevice_id bigint, in idatetime timestamptz, in ilongitude double precision, in ilatitude double precision, in ihdop double precision) returns void as $$
declare
    filtered_lat double precision;
    filtered_lon double precision;
    p float8[][];
    state jsonb;
begin
    if ihdop is null or ihdop <= 0 then
        ihdop := 1.0; -- assume a default hdop of 1.0 if not provided
    end if;
    state := (select current_state from kalman.devices where id=idevice_id);
    if state is null then
        -- initialize state
        filtered_lat := ilatitude;
        filtered_lon := ilongitude;
        p := ARRAY[
                [0.001, 0.0],
                [0.0, 0.001]
            ];
        state := jsonb_build_object(
                    'lat', filtered_lat,
                    'lon', filtered_lon,
                    'p', p,
                    'time', idatetime
                );
        insert into kalman.devices (id, current_state) values (idevice_id, state)
            on conflict (id) do update set current_state=excluded.current_state;
    else
        -- apply kalman filter step
        select est_lat, est_lon, updated_P into filtered_lat, filtered_lon, p
        from kalman.kalman_step(
                (state->>'lat')::double precision,
                (state->>'lon')::double precision,
                array[
                    array[(state->'p'->0->>0)::float8, (state->'p'->0->>1)::float8],
                array[(state->'p'->1->>0)::float8, (state->'p'->1->>1)::float8]
                    ],
                ilatitude,
                ilongitude,
                (state->>'time')::timestamptz,
                idatetime,
                ihdop,
                5.0     -- assume sigma_m=5 meters
             );

        state := jsonb_build_object(
                            'lat', filtered_lat,
                            'lon', filtered_lon,
                            'p', jsonb_build_array(
                                            jsonb_build_array(p[1][1], p[1][2]),
                                            jsonb_build_array(p[2][1], p[2][2])
                                        ),
                            'time', idatetime
                        );

        update kalman.devices set current_state=state where id=idevice_id;
    end if;

    insert into kalman.positions (device_id, datetime, longitude, latitude, hdop, filtered_longitude, filtered_latitude) values (idevice_id, idatetime, ilongitude, ilatitude, ihdop, filtered_lon, filtered_lat)
        on conflict (device_id, datetime) do update set longitude=excluded.longitude, latitude=excluded.latitude, hdop=excluded.hdop, filtered_longitude=excluded.filtered_longitude, filtered_latitude=excluded.filtered_latitude;
end;
$$ language plpgsql;

-- helper functions / type for the custom aggregate

CREATE TYPE kalman.kalman_state AS (
    est_lat DOUBLE PRECISION,
    est_lon DOUBLE PRECISION,
    P FLOAT8[][],
    last_time TIMESTAMPTZ
);

CREATE FUNCTION kalman.kalman_filter_agg_transfn(
    state kalman.kalman_state,
    curr_lat DOUBLE PRECISION,
    curr_lon DOUBLE PRECISION,
    curr_time TIMESTAMPTZ,
    hdop DOUBLE PRECISION,
    sigma_m DOUBLE PRECISION
)
    RETURNS kalman.kalman_state
    LANGUAGE plpgsql AS
$$
DECLARE
    est_lat_n DOUBLE PRECISION;
    est_lon_n DOUBLE PRECISION;
    updated_P_n FLOAT8[][];
BEGIN
    IF state IS NULL THEN
        -- initial state
        RETURN (curr_lat, curr_lon, ARRAY[[0.001, 0],[0,0.001]]::float8[2][2], curr_time);
    END IF;

    -- Aufruf des Kalman-Filters mit letztem Zustand
    SELECT est_lat, est_lon, updated_P
        INTO est_lat_n, est_lon_n, updated_P_n
        FROM kalman.kalman_step(
            state.est_lat,
            state.est_lon,
            state.P,
            curr_lat,
            curr_lon,
            state.last_time,
            curr_time,
            hdop,
            sigma_m
        );

    RETURN (est_lat_n, est_lon_n, updated_P_n, curr_time);
END;
$$;

CREATE AGGREGATE kalman.kalman_filter_agg(
    curr_lat DOUBLE PRECISION,
    curr_lon DOUBLE PRECISION,
    curr_time TIMESTAMPTZ,
    hdop DOUBLE PRECISION,
    sigma_m DOUBLE PRECISION
) (
    SFUNC = kalman.kalman_filter_agg_transfn,
    STYPE = kalman.kalman_state
    -- no INITCOND, NULL initial is valid and will be handled in SFUNC
);

-- example usage of the on-line data filtering
select kalman.upsert_position(1, '2025-09-09T12:00:00Z', 8.5417, 47.3769, 1.0);

select * from kalman.positions;

select kalman.upsert_position(1, '2025-09-09T12:00:10Z', 8.5421, 47.3772, 1.0);

select * from kalman.positions;
select * from kalman.devices;

-- example usage of the kalman filter step in a recursive CTE query
with recursive prev_row as (
    select *
    from pos
    where rn = 1
    union all
    select t.rn, t.datetime, t.longitude, t.latitude, t.hdop,
           (kalman.kalman_step(p.est_lat, p.est_lon, p.p, t.latitude, t.longitude, p.datetime, t.datetime, t.hdop, 5.0)).est_lon as est_lon,
           (kalman.kalman_step(p.est_lat, p.est_lon, p.p, t.latitude, t.longitude, p.datetime, t.datetime, t.hdop, 5.0)).est_lat as est_lat,
           (kalman.kalman_step(p.est_lat, p.est_lon, p.p, t.latitude, t.longitude, p.datetime, t.datetime, t.hdop, 5.0)).updated_P as p
    from prev_row p
             join pos t on t.rn = p.rn+ 1
),
pos as (
    select row_number() over (order by datetime) as rn, datetime, longitude, latitude, hdop, longitude as est_lon, latitude as est_lat, ARRAY[ [0.001,0.0], [0.0,0.001]]::float8[2][2] as p
    from kalman.positions where device_id=1 and datetime >= '2025-09-09T00:00:00Z' and datetime <= '2025-09-10T00:00:00Z' order by datetime
)
select st_makeline(st_makepoint(est_lon,est_lat)) as filtered_with_hdop, 'filtered_with_hdop' as name
from prev_row;

-- example usage of the kalman filter aggregate function
with pos as (
    select row_number() over (order by datetime) as rn, datetime, longitude, latitude, hdop, longitude as est_lon, latitude as est_lat, ARRAY[ [0.001,0.0], [0.0,0.001]]::float8[2][2] as p from kalman.positions where
        device_id=1 and datetime >= '2025-09-09T00:00:00Z' and datetime <= '2025-09-10T00:00:00Z' order by datetime
)
SELECT
    st_makeline(st_makepoint(
        (kstate).est_lon,
        (kstate).est_lat))
FROM (
    SELECT kalman.kalman_filter_agg(latitude, longitude, datetime, hdop, 5.0) over (order by datetime rows between unbounded preceding and current row) AS kstate
    FROM pos ORDER BY datetime
) AS sub;