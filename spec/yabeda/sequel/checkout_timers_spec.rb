# frozen_string_literal: true

RSpec.describe Yabeda::Sequel::CheckoutTimers do
  it "drops inherited completed intervals but records fresh child checkouts" do
    timers = described_class.new
    timers.start(Thread.current, :default, 10)
    timers.finish(Thread.current, :default, finished_at: 12)
    child_pid = Process.pid + 1
    allow(Process).to receive(:pid).and_return(child_pid)

    expect(timers.drain).to be_empty
    timers.start(Thread.current, :default, 1000)
    timers.finish(Thread.current, :default, finished_at: 1003)
    expect(timers.drain).to eq(default: 3)
  end
end
