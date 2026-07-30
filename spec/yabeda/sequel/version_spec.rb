# frozen_string_literal: true

RSpec.describe Yabeda::Sequel do
  it "has a semantic version number" do
    expect(Yabeda::Sequel::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end
end
