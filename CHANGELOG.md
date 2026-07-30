# Changelog

## 0.1.0 (unreleased)

Initial release.

- Connection pool metrics: open connections, ceiling, waiters, checkout wait time histogram, and pool timeout counter, labelled by database and pool server.
- Async thread pool metrics for the `concurrent_thread_pool` extension: live threads, queue depth, and thread ceiling.
- Per-process sampler thread so gauges stay correct under forking servers, rather than reflecting only whichever process served the scrape.
- Normalizes all six Sequel connection pool implementations, including the `sharded_single` case that advertises several servers but keeps one pool-wide size.
- Configuration through `anyway_config` (`YABEDA_SEQUEL_*`), with an `error_handler` hook and an `instrument_checkouts` kill switch.
- Rails Railtie that starts the sampler automatically.
