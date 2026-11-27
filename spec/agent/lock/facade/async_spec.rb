# frozen_string_literal: true

RSpec.describe Agent::Lock::Facade::Async, type: :checkout do
  subject(:facade) { Agent::Lock::Facade.new(strategies: %w[file], agent_id: "luke-backend", async: true) }

  it "answers with a future fulfilled by the facade's own result" do
    future = facade.async.acquire("workflow/**", "rewriting billing", dir: checkout)

    expect(future).to be_a(Concurrent::Promises::Future)
    expect(future.value!.status).to eq(:acquired)
  end

  it "passes keywords through, so the named holder signs the lock in the named checkout" do
    record = facade.async.acquire("workflow/**", "billing", dir: checkout, agent_id: "rey-frontend").value!.record

    expect([record.agent_id, record.intent]).to eq(%w[rey-frontend billing])
    expect(facade.check("workflow/**", dir: checkout, agent_id: "rey-frontend").status).to eq(:mine)
  end

  it "rejects the future with the refusal, which value! raises" do
    facade.acquire("workflow/**", dir: checkout)
    future = facade.async.acquire("workflow/**", dir: checkout, agent_id: "rey-frontend").wait

    expect([future.rejected?, future.value, future.reason]).to match([true, nil, an_instance_of(Agent::Lock::Refused)])
    expect { future.value! }.to raise_error(Agent::Lock::Refused)
  end

  it "passes a block through to acquire, which releases afterwards" do
    value = facade.async.acquire("workflow/**", dir: checkout, &:status).value!

    expect(value).to eq(:acquired)
    expect(facade.check("workflow/**", dir: checkout).status).to eq(:free)
  end

  it "leaves direct calls synchronous" do
    expect(facade.acquire("workflow/**", dir: checkout)).to be_a(Agent::Lock::Manager::Result)
  end

  it "is offered only by a facade built with async: true" do
    plain = Agent::Lock::Facade.new(strategies: %w[file])

    expect { plain.async }.to raise_error(ArgumentError, /async: true/)
  end

  it "names the gem to add when concurrent-ruby is missing" do
    allow(described_class).to receive(:require).with("concurrent").and_raise(LoadError, "cannot load such file")

    expect { Agent::Lock::Facade.new(strategies: %w[file], async: true) }
      .to raise_error(LoadError, /concurrent-ruby/)
  end

  context "with the Redis store" do
    subject(:facade) do
      Agent::Lock::Facade.new(strategies: %w[redis], redis_url: RedisHelpers::TEST_REDIS_URL, async: true)
    end

    before { skip "no Redis on #{RedisHelpers::TEST_REDIS_URL}" unless redis_reachable?(RedisHelpers::TEST_REDIS_URL) }

    it "signs the named holder in the named checkout" do
      record = facade.async.acquire("workflow/**", dir: checkout, agent_id: "rey-frontend").value!.record

      expect(record.agent_id).to eq("rey-frontend")
      expect(facade.async.release("workflow/**", dir: checkout, agent_id: "rey-frontend").value!.status)
        .to eq(:released)
    end
  end
end
