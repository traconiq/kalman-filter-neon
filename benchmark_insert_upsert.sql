-- use the upsert function to insert randomized positions
SELECT kalman.upsert_position(
               3,
               now(),
               8.5417 + (random()-0.5)*0.0003,
               47.3769 + (random()-0.5)*0.0002,
               1.0
       );
