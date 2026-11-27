# frozen_string_literal: true

# Redis only. The file store cannot answer these, and a checkout's backend
# marker must not send them there.
RSpec.describe Agent::Lock::CLI::Commands::Show do
  include_context "a CLI"

  let(:url) { RedisHelpers::TEST_REDIS_URL }

  before do
    skip "no Redis on #{url}" unless redis_reachable?(url)
    set_environment_variable("REDIS_URL", url)
    system("git", "-C", expand_path("."), "remote", "add", "origin",
           "git@github.com:kigster/laser-cutter.git", out: File::NULL, err: File::NULL)
    Redis.new(url: url).flushdb
  end

  after { Redis.new(url: url).flushdb if redis_reachable?(url) }

  it "tables the repositories in that Redis" do
    agent_lock("acquire workflow 'cutting' -u #{url}")

    command = agent_lock("show repos -u #{url}")
    major, minor, = Agent::Lock::VERSION.split(".")

    aggregate_failures do
      expect(command).to have_exit_status(0)
      expect(command.stdout).to include("Namespace")
      expect(command.stdout).to include("alock-#{major}.#{minor}-kigster/laser-cutter")
      expect(command.stdout).to include("Memory")
    end
  end

  it "tables one repository, including the command that breaks a lock" do
    agent_lock("acquire workflow 'cutting' -u #{url}")

    command = agent_lock("show repo kigster/laser-cutter -u #{url}")

    aggregate_failures do
      expect(command).to have_exit_status(0)
      expect(command.stdout).to include("workflow/**")
      expect(command.stdout).to include("test-agent")
      expect(command.stdout).to include("yes")
      expect(command.stdout).to include("break")
      expect(command.stdout).to include("workflow/**")
    end
  end

  it "says when that repository holds nothing" do
    command = agent_lock("show repo kigster/laser-cutter -u #{url}")

    expect(command.stdout).to include("No locks for kigster/laser-cutter.")
  end

  it "refuses a repository that is not owner/name" do
    command = agent_lock("show repo laser-cutter -u #{url}")

    aggregate_failures do
      expect(command).to have_exit_status(2)
      expect(command.stderr).to include("owner/name")
    end
  end

  it "exits 2 when that Redis does not answer, and does not read the file store" do
    command = agent_lock("show repos -u redis://127.0.0.1:1/15")

    aggregate_failures do
      expect(command).to have_exit_status(2)
      expect(command.stderr).to include("cannot use Redis")
    end
  end
end
