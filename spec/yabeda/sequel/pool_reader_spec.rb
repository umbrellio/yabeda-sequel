# frozen_string_literal: true

# Declared outside the example group so it isn't a leaky constant.
#
# The pool class is always requested explicitly: Sequel's default depends on the
# Ruby version (timed_queue from 3.2, threaded before), so relying on the default
# would make these expectations shift under the CI matrix.
#
# :expected_servers is what the reader should report, which is not always
# pool.servers — see the sharded_single note in PoolReader.
POOL_CASES = {
  single: {
    build: -> { Sequel.mock(single_threaded: true) },
    max_size: 1, waiting: false, expected_servers: [:default]
  },
  sharded_single: {
    build: -> { Sequel.mock(single_threaded: true, servers: { slave: {} }) },
    max_size: 1, waiting: false, expected_servers: [:default]
  },
  timed_queue: {
    build: -> { Sequel.mock(pool_class: :timed_queue) },
    max_size: 4, waiting: true, expected_servers: [:default]
  },
  sharded_timed_queue: {
    build: -> { Sequel.mock(pool_class: :sharded_timed_queue, servers: { slave: {} }) },
    max_size: 4, waiting: true, expected_servers: %i[default slave]
  },
  threaded: {
    build: -> { Sequel.mock(pool_class: :threaded) },
    max_size: 4, waiting: false, expected_servers: [:default]
  },
  sharded_threaded: {
    build: -> { Sequel.mock(pool_class: :sharded_threaded, servers: { slave: {} }) },
    max_size: 4, waiting: false, expected_servers: %i[default slave]
  },
}.freeze

RSpec.describe Yabeda::Sequel::PoolReader do
  POOL_CASES.each do |type, expectations|
    context "with a #{type} pool" do
      let(:db) { expectations[:build].call }
      let(:reader) { described_class.new(db.pool) }

      before do
        if type.to_s.include?("timed_queue") && !TIMED_QUEUE_SUPPORTED
          skip("#{type} needs Ruby 3.2+ and a Sequel that ships it")
        end
      end

      it "exercises the expected pool implementation" do
        expect(db.pool.pool_type).to eq(type)
      end

      it "is supported" do
        expect(described_class).to be_supported(db.pool)
      end

      it "reports the ceiling" do
        expect(reader.max_size).to eq(expectations[:max_size])
      end

      it "reports only servers whose size can be read independently" do
        expect(reader.servers).to eq(expectations[:expected_servers])
      end

      it "reports connections per reported server without an arity error" do
        reader.servers.each do |server|
          expect(reader.connections(server)).to be_a(Integer)
        end
      end

      it "counts a connection once one has been checked out" do
        db.synchronize { nil }
        expect(reader.connections(:default)).to eq(1)
      end

      it "reports a waiter count only when the pool tracks one" do
        if expectations[:waiting]
          expect(reader.waiting(:default)).to eq(0)
        else
          expect(reader.waiting(:default)).to be_nil
        end
      end
    end
  end

  it "does not double count a sharded_single pool across its servers" do
    db = Sequel.mock(single_threaded: true, servers: { slave: {} })
    reader = described_class.new(db.pool)

    # The pool itself advertises two servers but keeps a single pool-wide size.
    expect(db.pool.servers).to contain_exactly(:default, :slave)
    expect(reader.servers).to eq([:default])
  end

  it "treats an unrecognised pool object as unsupported" do
    expect(described_class).not_to be_supported(Object.new)
  end
end
