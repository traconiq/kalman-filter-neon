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
