# frozen_string_literal: true

require "yabeda/prometheus"
require "prometheus/client/data_stores/direct_file_store"
require "prometheus/client/formats/text"

# On Ruby 4.0+ CGI.parse lives in cgi/core rather than cgi, and DirectFileStore
# needs it to decode label sets back out of its files. A Rails host loads it
# transitively; a bare process like this one has to ask for it.
require "cgi/core"

# Requiring yabeda/prometheus does not register the adapter globally, so loading
# it here does not disturb the test adapter the rest of the suite relies on.
RSpec.describe "Prometheus export" do
  describe "exported metric names" do
    let(:adapter) { Yabeda::Prometheus::Adapter.new }

    it "suffixes the wait histogram with its unit exactly once" do
      expect(adapter.send(:build_name, Yabeda.sequel.connection_pool_wait))
        .to eq(:sequel_connection_pool_wait_seconds)
    end

    it "keeps the explicit _total on the timeouts counter" do
      expect(adapter.send(:build_name, Yabeda.sequel.connection_pool_timeouts_total))
        .to eq(:sequel_connection_pool_timeouts_total)
    end

    it "exports busy seconds with its explicit unit and counter suffix" do
      registry = Prometheus::Client::Registry.new
      allow(adapter).to receive(:registry).and_return(registry)
      metric = Yabeda.sequel.connection_pool_busy_seconds_total
      adapter.register_counter!(metric)
      adapter.perform_counter_increment!(metric, { db: "shop", server: "slave" }, 2.5)

      output = Prometheus::Client::Formats::Text.marshal(registry)
      expect(output).to include("# TYPE sequel_connection_pool_busy_seconds_total counter")
      expect(output).to include(
        'sequel_connection_pool_busy_seconds_total{db="shop",server="slave"} 2.5',
      )
    end

    it "prefixes every metric with the group name" do
      Yabeda.metrics.each_value do |metric|
        next unless metric.group == :sequel

        expect(adapter.send(:build_name, metric).to_s).to start_with("sequel_")
      end
    end
  end

  # The regression test for the behaviour yabeda-activerecord tracks as issue #7:
  # under a forking server each process writes its own store file, and the whole
  # design rests on the exporter folding those files together by aggregation mode.
  describe "multiprocess aggregation" do
    let(:dir) { Dir.mktmpdir("yabeda-sequel") }
    let(:previous_store) { Prometheus::Client.config.data_store }

    before do
      previous_store
      Prometheus::Client.config.data_store =
        Prometheus::Client::DataStores::DirectFileStore.new(dir: dir)
    end

    after do
      Prometheus::Client.config.data_store = previous_store
      FileUtils.remove_entry(dir)
    end

    # NOTE: #get deliberately reads only the calling process's own store file.
    # Aggregation across processes happens exclusively in #all_values, which is
    # what #values and the text formatter go through — so that is what the whole
    # design rests on, and what these examples assert.
    it "does not aggregate through #get, which reads only the local file" do
      gauge = build_gauge(:sequel_connection_pool_processes, [:db])

      fork_setting(gauge, 1, db: "shop")

      expect(gauge.get(labels: { db: "shop" })).to eq(0.0)
    end

    it "sums a per-process gauge across forked children" do
      gauge = build_gauge(:sequel_connection_pool_processes, [:db])

      3.times { fork_setting(gauge, 1, db: "shop") }

      expect(gauge.values).to eq({ db: "shop" } => 3.0)
    end

    it "sums connection counts across processes so a fleet total is derivable" do
      gauge = build_gauge(:sequel_connection_pool_connections, %i[db server])

      [4, 6].each { |count| fork_setting(gauge, count, db: "shop", server: "default") }

      expect(gauge.values).to eq({ db: "shop", server: "default" } => 10.0)
    end

    it "renders the summed value in the scrape output" do
      registry = Prometheus::Client::Registry.new
      gauge = build_gauge(:sequel_connection_pool_processes, [:db], registry: registry)

      2.times { fork_setting(gauge, 1, db: "shop") }

      output = Prometheus::Client::Formats::Text.marshal(registry)
      expect(output).to include('sequel_connection_pool_processes{db="shop"} 2.0')
    end

    def build_gauge(name, labels, registry: Prometheus::Client::Registry.new)
      registry.gauge(
        name,
        docstring: "#{name} under test",
        labels: labels,
        store_settings: { aggregation: :sum },
      )
    end

    # Each child writes to its own store file, which is exactly the multiprocess
    # shape a forking web server produces.
    def fork_setting(gauge, value, labels)
      pid = fork do
        gauge.set(value, labels: labels)
        exit!(0)
      end
      Process.wait(pid)
    end
  end
end
