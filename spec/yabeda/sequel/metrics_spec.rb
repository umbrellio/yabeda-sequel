# frozen_string_literal: true

RSpec.describe Yabeda::Sequel::Metrics do
  it "aggregates every metric by sum so per-process files fold into a fleet total" do
    %i[
      connection_pool_processes connection_pool_connections connection_pool_size
      connection_pool_waiting connection_pool_wait connection_pool_timeouts_total
      connection_pool_busy_seconds_total
      async_pool_threads async_pool_queue async_pool_max_threads
    ].each do |name|
      expect(Yabeda.sequel.send(name).aggregation).to eq(:sum), "#{name} must aggregate by sum"
    end
  end

  it "tags pool metrics by db and server" do
    expect(Yabeda.sequel.connection_pool_connections.tags).to contain_exactly(:db, :server)
  end

  it "tags per-database metrics by db only" do
    expect(Yabeda.sequel.connection_pool_processes.tags).to contain_exactly(:db)
    expect(Yabeda.sequel.async_pool_queue.tags).to contain_exactly(:db)
  end

  it "declares the wait metric as a histogram in seconds" do
    metric = Yabeda.sequel.connection_pool_wait
    expect(metric).to be_a(Yabeda::Histogram)
    expect(metric.unit).to eq(:seconds)
  end

  it "uses buckets topping out at Sequel's default pool timeout" do
    expect(Yabeda.sequel.connection_pool_wait.buckets.last).to eq(5)
  end

  it "declares timeouts as a counter carrying its own _total suffix" do
    expect(Yabeda.sequel.connection_pool_timeouts_total).to be_a(Yabeda::Counter)
  end

  it "declares busy seconds as a counter tagged by pool" do
    metric = Yabeda.sequel.connection_pool_busy_seconds_total
    expect(metric).to be_a(Yabeda::Counter)
    expect(metric.tags).to contain_exactly(:db, :server)
  end

  # Adapters build the exported name as [group, name, unit].compact.join("_").
  # The rendered name is asserted end to end in the Prometheus export spec; this
  # just pins the parts so a stray unit: on another metric is caught here.
  it "composes the wait metric name without doubling the unit suffix" do
    metric = Yabeda.sequel.connection_pool_wait
    expect([metric.group, metric.name, metric.unit].compact.join("_"))
      .to eq("sequel_connection_pool_wait_seconds")
  end

  it "leaves every other metric free of a unit suffix" do
    group_metrics = Yabeda.metrics.values.select { |metric| metric.group == :sequel }
    expect(group_metrics).not_to be_empty

    group_metrics.each do |metric|
      next if metric.name == :connection_pool_wait

      expect(metric.unit).to be_nil, "#{metric.name} should not declare a unit"
    end
  end
end
