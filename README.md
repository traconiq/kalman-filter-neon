# Implementing an In-Database Kalman Filter for GPS tracks

Modern GPS datasets are notoriously noisy: satellites shift, urban canyons scatter signals, and consumer device limitations introduce frequent errors. Smoothing and outlier correction right inside the database enables scalable postprocessing and analytics on millions of position samples — and the Kalman Filter is the technique of choice. Moreover, the filter can also be applied in an on-line fashion, smoothing the positional data at the moment it is collected and entered into the database.

## Background

The Kalman Filter is an efficient recursive algorithm to estimate the true state of a dynamic system (like a moving vehicle) from noisy measurements. At each timestep, it predicts the next state using a motion model (the "prediction" step), then corrects that guess using the latest observed value (the "update" step). It rigorously models uncertainties (noise) in both the process and measurement, continually refining position and optionally velocity estimates as new data arrives. This has made Kalman Filters invaluable for navigation, signal processing, and finance, among other fields.

For implementing a Kalman Filter in SQL to directly filter positional data in-database, several key points need to be considered:

- *State*: the Kalman Filter requires the position estimation and the covariance matrix (representing the uncertainty) of the previous step in order to perform the estimation of the current step.
- *Transition*: Based on the state and the current position measurement, a user-defined function is applied to generate the position update estimate. In addition to the pure position information, more sensory data can be added to this function to either manipulate the uncertainty (covariance matrix) or to skip the estimate completely. Such sensory data may be the HDOP (horizontal dilusion of precision) value of the GPS device, or the current speed (measured via a different set of sensors).
- *Sequencing*: the timely order of the data records is essential, as the Kalman Filter requires the data sets to be processed in sequence. For the off-line processing of data, this results in two possible ways of implementation: recursive queries or custom aggregate functions.

## On-line filtering

The on-line filtering of incoming data is pretty straightforward, all that is required is a user defined function to transition from the latest state (position estimate and covariance matrix) and the current position measurement to the current position estimate. The position estimate and covariance matrix can be stored as part of the device data of a GPS device, thus the previous covariance matrix and the previous estimate is always readily available.

## Off-line filtering

The off-line filtering is considerably more difficult to implement in SQL. As mentioned above, the sequential processing of the positional data poses a challenge which can be solved in two different ways.

1. *Recursive query*:
Recursive Common Table Expressions (CTEs) can step through the ordered GPS history, carrying the filter state forward for each record. This method has high transparency; you can see each intermediate state and annotate the "track" with diagnostics.
2. *Custom aggregate*:
Custom aggregate functions combine rows by repeatedly applying the filter function, storing the state "under the hood" and outputting the final (or intermediate) track. Aggregates are cleaner for batch postprocessing and fit standard SQL analytics workflows.

## Example usage

The script `example-schema.sql` creates a schema named `kalman` containing two tables:

- `kalman.positions` to store the raw GPS points as well as the filtered positions (which are created during online-filtering),
- `kalman.devices` to store the device information, here it consists only of an id and the last position estimate and the last covariance matrix.

Moreover, all functions to perform on-line and off-line filtering are created in this script.
The main function to perform the Kalman filter step is `kalman.kalman_step`, which is used when filtering in on-line or off-line mode.
The function `kalman.kalman_upsert_position` performs the on-line filtering during the insert of a new GPS point.

The example usage is demonstrated in the script `example_usage.sql`, which inserts some sample data, and applies the Kalman filter both in an on-line fashion (during insert) and in an off-line fashion (using both a recursive query and a custom aggregate function).

## Benchmarks

The benchmarks are created using `pgbench` and the four scripts

- `benchmark_insert_nofilter.sql` for inserting GPS points without any filtering,
- `benchmark_insert_upsert.sql` for inserting GPS points with on-line filtering,
- `benchmark_offline_recursive.sql` for using off-line filtering via a recursive query,
- `benchmark_offline_aggregate.sql` for using off-line filtering via a custom aggregate function.

### Insert without / with on-line filter

Bencharking using the `benchmark_insert_nofilter.sql` and `benchmark_insert_upsert.sql` scripts yields the following results:

|        TEST                 |  INSERT NO FILTER   |  INSERT WITH FILTER |
|-----------------------------|---------------------|---------------------|
| number of clients           |         1           |          1          |
| number of transactions      |        1000         |        1000         |
| latency avg (ms)            |        8.543        |       13.560        |
| tps (excluding connections) |      117.048322     |       73.743893     |

### Off-line filter via recursive query / custom aggregate

Bencharking using the `benchmark_offline_recursive.sql` and `benchmark_offline_aggregate.sql` scripts yields the following results:

| TEST                          |  OFFLINE RECURSIVE  |  OFFLINE AGGREGATE  |
|-------------------------------|---------------------|---------------------|
| number of clients             |         1           |          1          |
| number of transactions        |        1000         |        1000         |
| latency avg (ms)              |        0.290        |        0.226        |
| tps (excluding connections)   |     3442.637060     |     4419.401171     |

(all benchmarks were performed on the same machine and with the same dataset: `pgbench -f <script>.sql -t 1000`)

## Conclusion

The benchmarks show that the on-line filtering of GPS points during the insert operation is feasible, but comes with a significant performance penalty.
The off-line filtering of GPS points using a recursive query is possible, but has a considerable overhead compared to using a custom aggregate function.
Thus, for off-line filtering of large datasets, the custom aggregate function is the preferred method.

