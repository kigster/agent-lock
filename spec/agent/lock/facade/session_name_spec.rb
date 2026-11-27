# frozen_string_literal: true

# A host that names its session instead of leaving it to the ancestry walk:
# an engine that restarts while its plan's work goes on.
RSpec.describe Agent::Lock::Facade::Session, type: :checkout do
  around { |example| with_env("AGENT_ID" => "", "CLAUDE_SESSION_ID" => "") { example.run } }

  let(:rey) { locker(agent_id: "rey-frontend") }

  def locker(**) = Agent::Lock::Facade.new(strategies: %w[file], **)

  describe "session_name:" do
    subject(:plan) { locker(session_name: "plan-003.00") }

    it "signs the lock with the name, and ties it to no process" do
      record = plan.acquire("workflow/**", dir: checkout).record

      expect([record.agent_id, record.pid]).to eq(["plan-003.00", nil])
    end

    it "is the parent of a call that names its own agent" do
      plan.acquire("workflow/**", dir: checkout)

      expect(plan.whoami(agent_id: "luke-backend").parent_id).to eq("plan-003.00")
      expect(plan.acquire("workflow/lib/cli.rb", dir: checkout, agent_id: "luke-backend").status).to eq(:acquired)
    end

    context "when the host that took the lock has exited" do
      before do
        Process.wait(fork do
          locker(session_name: "plan-003.00").acquire("workflow/**", dir: checkout)
          exit!(0)
        end)
      end

      it "still holds the scope against everybody else" do
        expect { rey.check("workflow/**", dir: checkout) }.to raise_error(Agent::Lock::Refused, /HELD.*plan-003.00/)
      end

      it "is found by a restarted host that gives the same name" do
        statuses = [plan.check("workflow/**", dir: checkout), plan.acquire("workflow/**", dir: checkout),
                    plan.note("workflow/**", "back again", dir: checkout), plan.release("workflow/**", dir: checkout)]

        expect(statuses.map(&:status)).to eq(%i[mine already_mine noted released])
      end
    end

    it "lapses once untouched for the stale window" do
      plan.acquire("workflow/**", dir: checkout)

      expect(rey.check("workflow/**", dir: checkout, stale_minutes: -1).status).to eq(:free)
    end

    it "is taken per call as well" do
      record = locker.acquire("workflow/**", dir: checkout, session_name: "plan-004.00").record

      expect([record.agent_id, record.pid]).to eq(["plan-004.00", nil])
    end

    it "refuses a name a shell would not read as one word" do
      ["plan 3", "", :plan, "plan$(x)", "plan\u00A0three"].each do |name|
        expect { locker(session_name: name) }.to raise_error(ArgumentError, /session_name must be letters/)
      end
    end

    it "gives way to AGENT_ID, and is then that holder's parent" do
      identity = with_env("AGENT_ID" => "luke-backend") { plan.whoami }

      expect([identity.id, identity.parent_id, identity.evidence[:pid]]).to eq(["luke-backend", "plan-003.00", nil])
    end

    it "is preferred to CLAUDE_SESSION_ID" do
      expect(with_env("CLAUDE_SESSION_ID" => "01Tms9skZQfGQs4y") { plan.whoami.id }).to eq("plan-003.00")
    end

    it "overrides the holder: of a facade for the call that passes it" do
      identity = locker(holder: :session).whoami(session_name: "plan-004.00")

      expect([identity.id, identity.evidence[:pid]]).to eq(["plan-004.00", nil])
    end

    it "becomes interrupted work, for its own holder too, when it lapses with notes in it" do
      plan.acquire("workflow/**", dir: checkout)
      plan.note("workflow/**", "halfway", dir: checkout)
      rey.list(dir: checkout, stale_minutes: -1)

      expect { plan.acquire("workflow/**", dir: checkout) }.to raise_error(Agent::Lock::Refused, /INTERRUPTED/)
      expect(plan.resume("workflow/**", dir: checkout).record.intent).to include("halfway")
    end

    context "with the Redis store" do
      subject(:plan) { redis_locker(session_name: "plan-003.00") }

      before do
        skip "no Redis on #{RedisHelpers::TEST_REDIS_URL}" unless redis_reachable?(RedisHelpers::TEST_REDIS_URL)
      end

      def redis_locker(**)
        Agent::Lock::Facade.new(strategies: %w[redis], redis_url: RedisHelpers::TEST_REDIS_URL, **)
      end

      it "is held after its host exits, and found by a host that gives the same name" do
        Process.wait(fork do
          redis_locker(session_name: "plan-003.00").acquire("workflow/**", dir: checkout)
          exit!(0)
        end)

        expect { redis_locker(agent_id: "rey-frontend").check("workflow/**", dir: checkout) }
          .to raise_error(Agent::Lock::Refused, /HELD.*plan-003.00/)
        expect(plan.release("workflow/**", dir: checkout).status).to eq(:released)
      end
    end
  end

  it "refuses holder: beside it, since a named session is tied to no process" do
    expect { locker(holder: :session, session_name: "plan-003.00") }
      .to raise_error(ArgumentError, /holder: does not go with session_name/)
  end
end
