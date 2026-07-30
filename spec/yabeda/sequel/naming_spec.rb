# frozen_string_literal: true

RSpec.describe Yabeda::Sequel::Naming do
  it "uses the database name when present" do
    db = Sequel.mock(database: "unetsafe_production")
    expect(described_class.call(db)).to eq("unetsafe_production")
  end

  it "falls back to the database type when there is no name" do
    expect(described_class.call(Sequel.mock)).to eq("mock")
  end

  it "falls back when the name is empty" do
    db = Sequel.mock(database: "")
    expect(described_class.call(db)).to eq("mock")
  end

  it "returns the same label in a forked child" do
    db = Sequel.mock(database: "shop")
    reader, writer = IO.pipe

    pid = fork do
      reader.close
      writer.write(described_class.call(db))
      writer.close
      exit!(0)
    end

    writer.close
    Process.wait(pid)
    expect(reader.read).to eq("shop")
  ensure
    reader&.close
  end
end
