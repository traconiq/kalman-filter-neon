-- offline filtering via recursive CTE
WITH RECURSIVE prev_row AS (
    SELECT * FROM pos WHERE rn = 1
    UNION ALL
    SELECT t.rn, t.datetime, t.longitude, t.latitude, t.hdop,
           kfs.est_lon, kfs.est_lat, kfs.updated_P AS p
    FROM prev_row p
             JOIN pos t ON t.rn = p.rn + 1
             CROSS JOIN LATERAL (
        SELECT * FROM kalman.kalman_step(
                p.est_lat, p.est_lon, p.p,
                t.latitude, t.longitude,
                p.datetime, t.datetime,
                t.hdop, 5.0
                      )
        ) AS kfs
),
pos AS (
    SELECT row_number() OVER (ORDER BY datetime) AS rn, datetime, longitude, latitude, hdop,
            longitude AS est_lon, latitude AS est_lat,
            ARRAY[[0.001,0.0],[0.0,0.001]]::float8[2][2] AS p
    FROM kalman.positions WHERE device_id = 1 ORDER BY datetime LIMIT 1000
)
SELECT * FROM prev_row;
