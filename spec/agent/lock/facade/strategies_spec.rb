# frozen_string_literal: true

RSpec.describe Agent::Lock::Facade::Strategies do
  describe ".parse" do
    it "keeps the order given" do
      expect(described_class.parse(%w[file redis])).to eq(%w[file redis])
    end

    it "reads filesystem, symbols and any case as the same names" do
      expect(described_class.parse([:Redis, "FileSystem", "file"])).to eq(%w[redis file])
    end

    it "accepts a single name" do
      expect(described_class.parse("redis")).to eq(%w[redis])
    end

    it "rejects an empty list" do
      expect { described_class.parse([]) }.to raise_error(ArgumentError, /at least one/)
    end

    it "rejects an unknown name" do
      expect { described_class.parse(%w[redis postgres]) }.to raise_error(ArgumentError, /"postgres"/)
    end
  end
end
