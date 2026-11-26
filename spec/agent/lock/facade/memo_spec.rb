# frozen_string_literal: true

RSpec.describe Agent::Lock::Facade::Memo do
  it "builds once and returns the same value after" do
    builds = 0
    memo = described_class.new { builds += 1 }

    2.times { memo.value }

    expect(builds).to eq(1)
  end

  it "builds once when many threads ask together" do
    builds = Queue.new
    memo = described_class.new do
      builds << true
      sleep 0.01
      Object.new
    end
    gate = Queue.new
    threads = Array.new(16) do
      Thread.new do
        gate.pop
        memo.value
      end
    end
    16.times { gate << true }

    expect(threads.map(&:value).uniq.size).to eq(1)
    expect(builds.size).to eq(1)
  end

  it "does not keep a build that raised, so the next call tries again" do
    attempts = 0
    memo = described_class.new do
      attempts += 1
      raise "down" if attempts == 1

      :up
    end

    expect { memo.value }.to raise_error(RuntimeError, "down")
    expect(memo.value).to eq(:up)
  end

  it "builds a new value after reset" do
    memo = described_class.new { Object.new }
    first = memo.value
    memo.reset

    expect(memo.value).not_to equal(first)
  end
end
