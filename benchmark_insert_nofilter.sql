-- insert data directly (no kalman filter) for benchmarking
INSERT INTO kalman.positions (device_id, datetime, longitude, latitude, hdop, filtered_longitude, filtered_latitude)
VALUES (2, now(), 8.5417 + (random()-0.5)*0.0003, 47.3769 + (random()-0.5)*0.0002, 1.0, NULL, NULL)
ON CONFLICT (device_id, datetime) DO UPDATE
    SET longitude = EXCLUDED.longitude,
        latitude = EXCLUDED.latitude,
        hdop = EXCLUDED.hdop;
