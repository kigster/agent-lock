# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Agent::Lock::Tree, type: :checkout do
  subject(:standing) { described_class.for(dir) }

  let(:dir) { checkout }

  its(:root) { is_expected.to eq(checkout) }

  describe "#relative" do
    it "takes a path typed from the root as it is" do
      expect(standing.relative("workflow/lib/cli.rb")).to eq("workflow/lib/cli.rb")
    end

    it "takes an absolute path back to the tree it is in" do
      expect(standing.relative(File.join(checkout, "workflow/lib/cli.rb"))).to eq("workflow/lib/cli.rb")
    end

    it "calls the root itself '.', so nobody mistakes it for a file named after the checkout" do
      expect(standing.relative(checkout)).to eq(".")
    end

    it "accepts a file that does not exist yet, since that is what an agent about to write one claims" do
      expect(standing.relative(File.join(checkout, "workflow/lib/new.rb"))).to eq("workflow/lib/new.rb")
    end

    context "when standing in a subdirectory" do
      let(:dir) { File.join(checkout, "workflow") }

      its(:root) { is_expected.to eq(checkout) }

      it "reads a relative path from where the agent stands" do
        expect(standing.relative("lib/cli.rb")).to eq("workflow/lib/cli.rb")
      end

      it "lets .. climb back up, as long as it stays inside" do
        expect(standing.relative("../docs")).to eq("docs")
      end
    end

    context "with a path outside the tree" do
      it "refuses it rather than lock an unrelated tree file that happens to share its basename" do
        expect { standing.relative("/etc/passwd") }
          .to raise_error(Agent::Lock::Scope::Invalid, "/etc/passwd is outside the tree #{checkout}")
      end

      it "refuses a .. that climbs out of the root" do
        expect { standing.relative("../elsewhere") }.to raise_error(Agent::Lock::Scope::Invalid, /outside the tree/)
      end

      it "does not mistake a sibling that shares the root's name as a prefix for the tree" do
        expect { standing.relative("#{checkout}-other/a.rb") }
          .to raise_error(Agent::Lock::Scope::Invalid, /outside the tree/)
      end
    end

    context "through a symlink" do
      around do |example|
        Dir.mktmpdir("agent-lock-links") do |links|
          @links = links
          example.run
        end
      end

      let(:alias_dir) { File.join(@links, "alias").tap { |path| File.symlink(checkout, path) } }

      it "reads a path spelled through an alias of the tree as the tree" do
        expect(standing.relative(File.join(alias_dir, "workflow/lib/cli.rb"))).to eq("workflow/lib/cli.rb")
      end

      it "resolves the alias even for a file that does not exist yet" do
        expect(standing.relative(File.join(alias_dir, "workflow/lib/new.rb"))).to eq("workflow/lib/new.rb")
      end

      it "does not count a symlinked working directory as outside" do
        expect(described_class.for(File.join(alias_dir, "workflow")).relative("lib")).to eq("workflow/lib")
      end

      # The lock is about names in the tree, and `vendor/gem.rb` is one, wherever
      # the link happens to point today.
      it "keeps an in-tree symlink's own name even when it points outside" do
        File.symlink(@links, File.join(checkout, "vendor"))

        expect(standing.relative("vendor/gem.rb")).to eq("vendor/gem.rb")
      end
    end
  end
end
