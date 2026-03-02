# prometheus

This is an experimental Prometheus implementation

https://prometheus.io/docs/introduction/overview/

## Usage

https://prometheus.hc.deney.io:9090/

Basic Auth Credentials:
username: prometheus
password xxxxxxxxxxxxx

The password is randomly generated during installation and saved to `/root/prometheus_basic_auth_password.txt`

From the web ui you can query to see how many targets are up:
```promql
up
```

With the `prometheus` target up you can query to see how many time series are currently in memory providing an indication that it is doing things.
```promql
prometheus_tsdb_head_series
```

The `table` view provides a specific point in time value, while the `graph` will show you how that value has changed over time.

To see the status of all targets go to:
https://prometheus.hc.deney.io:9090/targets

## TODO

- [x] install prometheus
- [x] configure prometheus
- [ ] get other systems metrics in prometheus
