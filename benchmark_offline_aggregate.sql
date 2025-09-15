-- offline filtering via aggregate window function
WITH pos AS (
    SELECT row_number() OVER (ORDER BY datetime) AS rn, datetime, longitude, latitude, hdop,
           longitude AS est_lon, latitude AS est_lat,
           ARRAY[[0.001,0.0],[0.0,0.001]]::float8[2][2] AS p
    FROM kalman.positions WHERE device_id = 1 ORDER BY datetime LIMIT 1000
)
select datetime, longitude, latitude, (kstate).est_lon,(kstate).est_lat from (SELECT kalman.kalman_filter_agg(latitude, longitude, datetime, hdop, 5.0)
                      OVER (ORDER BY datetime ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) as kstate,*
               FROM pos) foo;
