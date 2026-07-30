# yabeda-sequel

[Yabeda](https://github.com/yabeda-rb/yabeda) plugin exposing Sequel connection pool and async thread pool metrics — designed to stay correct under forking servers such as Puma in clustered mode.

## Why a sampler rather than a collect block

The obvious implementation is a Yabeda `collect` block that reads the pool at scrape time. Under a forking server that quietly breaks: only the process that happens to serve `/metrics` runs the block, so every other worker's gauges reflect nothing. `yabeda-activerecord` tracks this as [issue #7](https://github.com/yabeda-rb/yabeda-activerecord/issues/7), still open.

This gem samples instead. Each process refreshes its own gauges on a background thread and writes them to its own metric store file; the Prometheus exporter sums across those files at scrape time. With `Prometheus::Client::DataStores::DirectFileStore`, `sum(sequel_connection_pool_connections)` is a genuine fleet-wide total.

Wait time is the exception — it's inherently per-checkout and cannot be sampled, so it's captured by instrumenting the pool directly.

## Installation

```ruby
gem "yabeda-sequel"
```

You also need a Yabeda adapter, e.g. `yabeda-prometheus`. Metric declarations are queued when this gem is required; your app (or `yabeda-rails`) registers them by calling `Yabeda.configure!`.

## Wiring

In a Rails app the bundled Railtie starts the sampler after initialization, so Sidekiq, Sneakers and single-mode Puma need nothing further.

**Clustered Puma needs fork hooks**, because a gem cannot reach into `config/puma.rb`:

```ruby
before_fork do
  Yabeda::Sequel.stop!
  # ...your existing before_fork work, including any DB disconnect
end

on_worker_boot do
  Yabeda::Sequel.start!
end
```

`Yabeda::Sequel.stop!` must run **before** anything that disconnects the database — the sampler reads the pool, so stopping it afterwards races.

Outside Rails, call `Yabeda::Sequel.start!` once per process after any fork. It is idempotent and pid-aware, so calling it twice is harmless and a forked child always gets its own thread.

## Metrics

All gauges are declared with `aggregation: :sum` so they fold across processes.

| Metric | Type | Labels | Meaning |
|---|---|---|---|
| `sequel_connection_pool_processes` | gauge | `db` | Processes reporting for this database |
| `sequel_connection_pool_connections` | gauge | `db`, `server` | Connections currently open |
| `sequel_connection_pool_size` | gauge | `db`, `server` | Maximum connections allowed |
| `sequel_connection_pool_waiting` | gauge | `db`, `server` | Threads waiting for a checkout |
| `sequel_connection_pool_wait_seconds` | histogram | `db`, `server` | Time spent waiting for a checkout |
| `sequel_connection_pool_timeouts_total` | counter | `db`, `server` | Checkouts that raised `Sequel::PoolTimeout` |
| `sequel_async_pool_threads` | gauge | `db` | Live threads in the async query pool |
| `sequel_async_pool_queue` | gauge | `db` | Tasks queued in the async query pool |
| `sequel_async_pool_max_threads` | gauge | `db` | Maximum threads the async pool may run |

`server` reflects whatever the pool actually has configured — `default` alone, or `default` plus any shards such as `slave`.

The `async_pool_*` metrics appear only when the database exposes `async_thread_executor` (the `concurrent_thread_pool` extension from [umbrellio-sequel-plugins](https://github.com/umbrellio/umbrellio-sequel-plugins)) and that executor can introspect itself.

### `connections / size` is not saturation

This trips people up, so it's worth stating plainly. Sequel pools grow to their high-water mark and never shrink — there's no idle reaper unless you load one. So `connections / size` climbs to 1.0 after the first busy period and stays there. It is **capacity accounting**: how many connections a process holds against how many it may hold. That's the number you want when reconciling a database's connection count against your fleet.

Actual saturation — is anything being starved — comes from elsewhere:

```promql
# Threads starved of a connection right now
sum by (job) (sequel_connection_pool_waiting)

# How long checkouts actually wait
histogram_quantile(0.99, sum by (le, job) (rate(sequel_connection_pool_wait_seconds_bucket[5m])))

# Hard failures
rate(sequel_connection_pool_timeouts_total[5m])
```

`waiting` is cheap but is a point-in-time sample, so it under-reports brief contention; the histogram catches what sampling misses. Use both.

Other useful queries:

```promql
# Fleet-wide connection total
sum(sequel_connection_pool_connections)

# How many processes are reporting
sum by (job) (sequel_connection_pool_processes)

# Async work backing up (the executor's queue is unbounded, so it backs up silently)
sum by (job) (sequel_async_pool_queue)
```

## Configuration

Via `anyway_config` — environment variables prefixed `YABEDA_SEQUEL_`, or `config/yabeda_sequel.yml`.

| Setting | Default | Purpose |
|---|---|---|
| `sample_interval` | `5` | Seconds between samples |
| `instrument_checkouts` | `true` | Kill switch for the wait/timeout instrumentation |
| `autostart` | `true` | Whether the Railtie starts the sampler |
| `wait_buckets` | `0.0005 … 5` | Histogram buckets; the top bucket is Sequel's default `pool_timeout` |

`error_handler` is a plain accessor rather than a config key, since a proc can't come from ENV or YAML. Point it at your error tracker:

```ruby
Yabeda::Sequel.config.error_handler = ->(error) { Sentry.capture_exception(error) }
```

A metric write never surfaces as an application failure — failures inside instrumentation go to `error_handler` and the query proceeds.

Set `YABEDA_SEQUEL_AUTOSTART=false` in test environments if you'd rather not have a background thread running.

## Supported pool implementations

Sequel ships six connection pools exposing different subsets of the same data, and this gem normalizes all of them:

| Pool | `num_waiting` | Per-server `size` |
|---|---|---|
| `timed_queue` | yes | no |
| `sharded_timed_queue` | yes | yes |
| `threaded` | no | no |
| `sharded_threaded` | no | yes |
| `single` | no | no |
| `sharded_single` | no | no |

The timed-queue pair needs Ruby 3.2+ *and* a Sequel recent enough to ship it; on older combinations Sequel defaults to the threaded pair. The gem detects what the pool can actually do rather than inferring it from either version, so both eras work.

`connection_pool_waiting` is simply absent on pools that don't track waiters. There are deliberately no `busy` / `idle` gauges: on the timed-queue pools those are only reachable through instance variables, and the public readers on the legacy pools are already marked for removal in Sequel 6.

`sharded_single` advertises multiple servers but keeps a single pool-wide size, so it is reported under `server="default"` only rather than double counted.

## Notes

**Ruby 4.0 and `DirectFileStore`.** `prometheus-client` calls `CGI.parse`, which moved from `cgi` to `cgi/core` in Ruby 4.0. A Rails host loads it transitively; a bare process may need `require "cgi/core"`.

**`acquire` is private Sequel API.** The wait histogram and timeout counter work by prepending the pool's singleton class around `acquire`, which is the only way to observe checkout wait time. The specs pin this so a Sequel release that changes it fails CI rather than silently flatlining the metric. If you're ever bitten by it, set `instrument_checkouts` to `false` — the sampled metrics keep working.

**Orphaned store files.** If a worker crashes, its `DirectFileStore` file keeps contributing until the pod or host is replaced. Absolute counts drift high; ratios stay honest because numerator and denominator inflate together.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
