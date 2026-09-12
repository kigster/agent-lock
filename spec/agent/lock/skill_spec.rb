# frozen_string_literal: true

require "tmpdir"

# The skill is the half of this gem an agent reads rather than runs, so it has
# to get into a skills directory without anybody going looking for where
# RubyGems unpacked it.
RSpec.describe Agent::Lock::Skill do
  subject(:skill) { described_class.new(into: into, source: source) }

  let(:home) { Dir.mktmpdir("skills-home") }
  let(:into) { File.join(home, "skills") }
  let(:target) { File.join(into, "agent-lock") }
  let(:source) do
    File.join(Dir.mktmpdir("skill-source"), "agent-lock").tap do |dir|
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "SKILL.md"), "---\nname: agent-lock\n---\n\nThe bundled copy.\n")
    end
  end

  after { FileUtils.rm_rf([home, File.dirname(source)]) }

  describe "the skill this gem ships" do
    subject(:markdown) { File.read(File.join(described_class.source, "SKILL.md")) }

    it { is_expected.to start_with("---\nname: agent-lock\n") }
    it { is_expected.to match(/^description: Use when /) }
  end

  describe "#install" do
    context "when the skills directory does not exist yet" do
      subject!(:result) { skill.install }

      its(:status) { is_expected.to eq(:installed) }
      its(:path) { is_expected.to eq(target) }

      it "copies the skill in" do
        expect(File.read(File.join(target, "SKILL.md"))).to include("The bundled copy.")
      end
    end

    context "when the same copy is already there" do
      before { skill.install }

      it "leaves it alone and says so" do
        expect(skill.install.status).to eq(:current)
      end
    end

    # A copy that differs may be one somebody edited on purpose. Overwriting it
    # without being asked would be the same silent last-writer-wins this gem
    # exists to stop.
    context "when a different copy is there" do
      before do
        FileUtils.mkdir_p(target)
        File.write(File.join(target, "SKILL.md"), "somebody's own edit\n")
      end

      it "refuses, and keeps that copy" do
        aggregate_failures do
          expect(skill.install.status).to eq(:differs)
          expect(File.read(File.join(target, "SKILL.md"))).to eq("somebody's own edit\n")
        end
      end

      it "replaces it when forced" do
        aggregate_failures do
          expect(skill.install(force: true).status).to eq(:installed)
          expect(File.read(File.join(target, "SKILL.md"))).to include("The bundled copy.")
        end
      end
    end

    # A symlink in a skills directory is somebody else's installer at work,
    # such as a dotfiles repo that links every skill it manages. Replacing it
    # would detach the skill from whatever keeps it up to date.
    context "when the name is a symlink" do
      let(:elsewhere) { Dir.mktmpdir("managed") }

      before do
        FileUtils.mkdir_p(into)
        File.symlink(elsewhere, target)
      end

      after { FileUtils.rm_rf(elsewhere) }

      it "leaves the link alone, even when forced" do
        aggregate_failures do
          expect(skill.install(force: true).status).to eq(:linked)
          expect(File.readlink(target)).to eq(elsewhere)
        end
      end
    end
  end
end
