# frozen_string_literal: true

RSpec.describe Agent::Lock::Facade, type: :checkout do
  let(:url_a) { "redis://127.0.0.1:6379/14" }
  let(:url_b) { "redis://127.0.0.1:6379/15" }

  before do
    skip "no Redis on #{url_a}" unless redis_reachable?(url_a)
  end

  after do
    [url_a, url_b].each do |url|
      Redis.new(url: url).flushdb
    rescue StandardError
      nil
    end
  end

  it "keeps locks taken on one URL invisible to a facade on another" do
    first = described_class.new(strategies: %w[redis], redis_url: url_a)
    second = described_class.new(strategies: %w[redis], redis_url: url_b)

    first.acquire("workflow/**", "on a", dir: checkout, agent_id: "a")

    expect(second.check("workflow/**", dir: checkout, agent_id: "b").status).to eq(:free)
    expect(first.check("workflow/**", dir: checkout, agent_id: "a").status).to eq(:mine)
  end

  it "memoizes distributed once Redis answers, apart from local" do
    Agent::Lock.reset_facades!
    with_env("REDIS_URL" => url_a) do
      held = Agent::Lock.distributed

      expect([Agent::Lock.distributed, held.backend_name]).to eq([held, "redis"])
      expect(held).not_to equal(Agent::Lock.local)
    end
  ensure
    Agent::Lock.reset_facades!
  end

  it "lets exactly one of several threads take a scope through one Redis facade" do
    facade = described_class.new(strategies: %w[redis], redis_url: url_a)
    outcomes = Array.new(8) do |index|
      Thread.new do
        facade.acquire("workflow/**", dir: checkout, agent_id: "agent-#{index}") && :acquired
      rescue Agent::Lock::Refused
        :refused
      end
    end.map(&:value)

    expect(outcomes.tally).to eq(acquired: 1, refused: 7)
  end

  it "shares locks when two facades are given the same URL" do
    first = described_class.new(strategies: %w[redis], redis_url: url_a, agent_id: "a")
    second = described_class.new(strategies: %w[redis], redis_url: url_a, agent_id: "b")

    first.acquire("workflow/**", dir: checkout)

    expect { second.acquire("workflow/lib/cli.rb", dir: checkout) }
      .to raise_error(Agent::Lock::Refused, /HELD/)
  end
end
