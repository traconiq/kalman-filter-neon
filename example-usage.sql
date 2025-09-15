-- example usage of the on-line data filtering

-- insert 200 pseudo-random GPS points with device_id=1 via upsert_position
WITH RECURSIVE track AS (
    SELECT
        1 AS device_id,
        '2025-09-09T12:00:00Z'::timestamptz AS datetime,
        8.5417::double precision AS longitude,
        47.3769::double precision AS latitude,
        1.0::double precision AS hdop,
        1 AS step
    UNION ALL
    SELECT
        device_id,
        datetime + INTERVAL '10 seconds',
        longitude + (random()-0.5)*0.0003,
        latitude + (random()-0.5)*0.0002,
        0.8 + random()*0.4,
        step + 1
    FROM track
    WHERE step < 200
)
SELECT kalman.upsert_position(device_id, datetime, longitude, latitude, hdop)
FROM track;

-- check inserted positions
select * from kalman.positions where device_id=1 order by datetime;

-- check device state
select * from kalman.devices;


-- off-line processing of existing data

-- example usage of the kalman filter step in a recursive CTE query
with recursive prev_row as (
    select *
    from pos
    where rn = 1
    union all
    select  t.rn, t.datetime, t.longitude, t.latitude, t.hdop,
            kfs.est_lon,
            kfs.est_lat,
            kfs.updated_P as p,
            t.filtered_longitude,
            t.filtered_latitude
    from prev_row p
             join pos t on t.rn = p.rn + 1
             cross join lateral (
        select *
        from kalman.kalman_step(
                p.est_lat,
                p.est_lon,
                p.p,
                t.latitude,
                t.longitude,
                p.datetime,
                t.datetime,
                t.hdop,
                5.0
             )
        ) as kfs
),
               pos as (
                   select row_number() over (order by datetime) as rn, datetime, longitude, latitude, hdop, longitude as est_lon, latitude as est_lat, ARRAY[ [0.001,0.0], [0.0,0.001]]::float8[2][2] as p, filtered_longitude, filtered_latitude
                   from kalman.positions where device_id=1 and datetime >= '2025-09-09T00:00:00Z' and datetime <= '2025-09-10T00:00:00Z' order by datetime
               )
select *, filtered_longitude-est_lon as diff_lon, filtered_latitude-est_lat as diff_lat
from prev_row;

-- example usage of the kalman filter aggregate function
with pos as (
    select row_number() over (order by datetime) as rn, datetime, longitude, latitude, hdop, longitude as est_lon, latitude as est_lat, ARRAY[ [0.001,0.0], [0.0,0.001]]::float8[2][2] as p, filtered_longitude, filtered_latitude from kalman.positions where
        device_id=1 and datetime >= '2025-09-09T00:00:00Z' and datetime <= '2025-09-10T00:00:00Z' order by datetime
)
SELECT
    *, (kstate).est_lon, (kstate).est_lat, (kstate).est_lon - filtered_longitude as diff_lon, (kstate).est_lat - filtered_latitude as diff_lat
FROM (
         SELECT kalman.kalman_filter_agg(latitude, longitude, datetime, hdop, 5.0) over (order by datetime rows between unbounded preceding and current row) AS kstate, *
         FROM pos ORDER BY datetime
     ) AS sub;