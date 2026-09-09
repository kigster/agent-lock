# frozen_string_literal: true

# `chflags` can refuse. A file somebody else owns, a filesystem that does not
# carry the flag, or no macOS at all: in every case the lock must record what
# is actually frozen rather than what it hoped to freeze.
RSpec.describe Agent::Lock::Freeze, type: :checkout do
  subject(:luke) { manager_for("luke-backend") }

  before { allow(described_class).to receive(:supported?).and_return(true) }

  # The real thing shells out. What matters here is what the gem does with the
  # answer, so the answer is the thing under control.
  def chflags_refusing(*paths)
    allow(described_class).to receive(:run) do |_flag, given|
      given.none? { |path| paths.any? { |refused| path.end_with?(refused) } }
    end
  end

  it "records the files it actually froze, not the ones it tried" do
    chflags_refusing("workflow/lib/cli.rb")
    File.write(File.join(checkout, "workflow", "lib", "other.rb"), "# stub\n")

    result = luke.acquire("workflow/**", enforce: true)

    aggregate_failures do
      expect(result.record.frozen_paths).to eq(["workflow/lib/other.rb"])
      expect(result.message).to include("could not freeze 1 of 2")
    end
  end

  it "says nothing about a shortfall when there is none" do
    allow(described_class).to receive(:run).and_return(true)

    expect(luke.acquire("workflow/**", enforce: true).message).to be_nil
  end

  it "thaws every path it recorded when the lock goes back" do
    allow(described_class).to receive(:run).and_return(true)
    luke.acquire("workflow/**", enforce: true)

    expect(described_class).to receive(:run).with("nouchg", array_including(/other|cli/))

    luke.release("workflow/**")
  end

  describe "when the freeze cannot happen at all" do
    it "refuses off macOS rather than pretending" do
      allow(described_class).to receive(:supported?).and_return(false)

      expect { luke.acquire("workflow/**", enforce: true) }
        .to raise_error(described_class::TooBroad, /needs macOS/)
    end

    # The claim is taken before anything is flagged, so a freeze that cannot
    # happen must not leave the lock behind either.
    it "leaves no lock behind" do
      allow(described_class).to receive(:supported?).and_return(false)
      suppress(described_class::TooBroad) { luke.acquire("workflow/**", enforce: true) }

      expect(luke.list.records).to be_empty
    end

    it "refuses a freeze wide enough to be a mistake" do
      stub_const("#{described_class}::LIMIT", 1)
      allow(described_class).to receive(:run).and_return(true)
      File.write(File.join(checkout, "workflow", "lib", "other.rb"), "# stub\n")

      expect { luke.acquire("workflow/**", enforce: true) }
        .to raise_error(described_class::TooBroad, /wider than a freeze should be/)
    end
  end

  def suppress(error)
    yield
  rescue error
    nil
  end
end
