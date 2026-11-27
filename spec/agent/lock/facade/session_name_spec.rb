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

    it "refuses a name with whitespace in it, or none" do
      ["plan 3", "", :plan].each do |name|
        expect { locker(session_name: name) }.to raise_error(ArgumentError, /session_name/)
      end
    end
  end

  it "refuses holder: beside it, since a named session is tied to no process" do
    expect { locker(holder: :session, session_name: "plan-003.00") }
      .to raise_error(ArgumentError, /holder: does not go with session_name/)
  end
end
