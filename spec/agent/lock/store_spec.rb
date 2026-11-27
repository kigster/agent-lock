# frozen_string_literal: true

# Backend selection on its own, apart from either backend's own behavior, so
# a regression here names the choice rather than surfacing as a mysterious
# failure in whichever backend it picked by accident.
RSpec.describe Agent::Lock::Store, type: :checkout do
  around do |example|
    with_env("AGENT_LOCK_BACKEND" => nil, &example)
  end

  def redis_reachable(reachable)
    allow(Agent::Lock::Store::RedisStore).to receive(:create_client)
      .and_return(reachable ? [instance_double(Redis), nil] : [nil, Agent::Lock::Error.new("down")])
  end

  describe ".for" do
    it "picks redis for a virgin tree when one answers locally" do
      redis_reachable(true)

      expect(described_class.for(tree)).to be_a(Agent::Lock::Store::RedisStore)
    end

    it "picks file for a virgin tree when none does" do
      redis_reachable(false)

      expect(described_class.for(tree)).to be_a(Agent::Lock::Store::FileSystemStore)
    end

    it "never probes redis once a marker is already recorded" do
      described_class.claim(tree, "file")

      expect(Agent::Lock::Store::RedisStore).not_to receive(:create_client)

      described_class.for(tree)
    end

    it "AGENT_LOCK_BACKEND wins over a live redis" do
      redis_reachable(true)

      with_env("AGENT_LOCK_BACKEND" => "file") do
        expect(described_class.for(tree)).to be_a(Agent::Lock::Store::FileSystemStore)
      end
    end

    it "refuses to switch a tree once a backend is recorded" do
      described_class.claim(tree, "file")

      with_env("AGENT_LOCK_BACKEND" => "redis") do
        expect { described_class.for(tree) }
          .to raise_error(Agent::Lock::Store::Mismatch, /release them before switching/)
      end
    end
  end

  describe ".claim" do
    it "records the proposed name on a virgin tree" do
      aggregate_failures do
        expect(described_class.claim(tree, "redis")).to eq("redis")
        expect(described_class.recorded(tree)).to eq("redis")
      end
    end

    # The race this exists to close: two processes reach a virgin tree and
    # propose different backends. Whichever wins the atomic create is what
    # both must end up building, or their locks would be invisible to
    # each other.
    it "hands back whatever a concurrent claim already wrote, not its own guess" do
      described_class.claim(tree, "redis")

      aggregate_failures do
        expect(described_class.claim(tree, "file")).to eq("redis")
        expect(described_class.recorded(tree)).to eq("redis")
      end
    end

    # The marker used to be created first and written after, so a thread
    # that lost the race could read "" and disagree with the winner.
    it "gives every concurrent claimant the same answer, never an empty one" do
      gate = Queue.new
      threads = Array.new(16) do |index|
        Thread.new do
          gate.pop
          described_class.claim(tree, index.even? ? "file" : "redis")
        end
      end
      16.times { gate << true }

      expect(threads.map(&:value).uniq).to eq([described_class.recorded(tree)])
    end

    it "names an unreadable marker as unreadable, not as empty" do
      skip "root reads any file" if Process.uid.zero?
      described_class.claim(tree, "file")
      File.chmod(0o000, described_class.marker_path(tree))

      expect { described_class.recorded(tree) }
        .to raise_error(Agent::Lock::Store::Mismatch, /cannot read .*backend: Permission denied/)
    ensure
      File.chmod(0o644, described_class.marker_path(tree))
    end

    it "reads a marker that exists but is still empty as no marker" do
      FileUtils.mkdir_p(File.dirname(described_class.marker_path(tree)))
      File.write(described_class.marker_path(tree), "")

      expect(described_class.recorded(tree)).to be_nil
    end

    # Each caller falling back to its own guess would split the tree.
    it "refuses a marker that stays empty rather than letting callers disagree" do
      allow(described_class).to receive(:sleep)
      FileUtils.mkdir_p(File.dirname(described_class.marker_path(tree)))
      File.write(described_class.marker_path(tree), "")

      expect { described_class.claim(tree, "file") }
        .to raise_error(Agent::Lock::Store::Mismatch, /exists but is empty/)
    end

    it "waits out an older alock that created the marker but has not written it yet" do
      path = described_class.marker_path(tree)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "")
      writer = Thread.new do
        sleep 0.05
        File.write(path, "redis\n")
      end

      expect(described_class.claim(tree, "file")).to eq("redis")
    ensure
      writer&.join
    end

    it "falls back to the exclusive create where hard links are not supported" do
      allow(File).to receive(:link).and_raise(Errno::ENOSYS)

      aggregate_failures do
        expect(described_class.claim(tree, "redis")).to eq("redis")
        expect(described_class.recorded(tree)).to eq("redis")
        expect(Dir.glob("#{described_class.marker_path(tree)}.*.tmp")).to be_empty
      end
    end
  end

  describe ".default_backend" do
    it "is redis when local_redis_available? is true" do
      redis_reachable(true)

      expect(described_class.default_backend).to eq("redis")
    end

    it "is file when local_redis_available? is false" do
      redis_reachable(false)

      expect(described_class.default_backend).to eq("file")
    end
  end
end
