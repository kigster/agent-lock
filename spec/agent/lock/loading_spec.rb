# frozen_string_literal: true

# Every file has to state what it needs.
#
# A file that uses Socket or FileUtils without requiring them works fine for as
# long as something else happens to require them first, and breaks the moment
# somebody loads it on its own or the require order changes. Loading each one
# in a process of its own is the only way to find that out.
RSpec.describe "loading a file on its own" do
  root = File.expand_path("../../../lib", __dir__)

  Dir.glob(File.join(root, "agent", "lock", "**", "*.rb")).each do |file|
    feature = file.delete_prefix("#{root}/").delete_suffix(".rb")

    it "requires everything #{feature} uses" do
      _out, err, status = Open3.capture3(RbConfig.ruby, "-I", root, "-e", "require #{feature.inspect}")

      aggregate_failures do
        expect(err).not_to include("uninitialized constant")
        expect(status).to be_success
      end
    end
  end
end
