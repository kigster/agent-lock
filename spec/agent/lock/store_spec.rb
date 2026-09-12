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
