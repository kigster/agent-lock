# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "timeout"
require "yard"

def shell(*args)
  puts "running: #{args.join(" ")}"
  system(args.join(" "))
end

desc "Clean all temporary files"
task :clean do
  shell("rm -rf pkg/ tmp/ coverage/ doc/ .yardoc/")
end

desc "Build the gem locally into pkg/"
task gem: [:build] do
  shell("gem install pkg/*")
end

desc "Set permissions on all files so that users can read them"
task permissions: [:clean] do
  # One traversal replaces a six-level glob chain that printed "No such file
  # or directory" for every level this project does not have, skipped dotfiles
  # entirely, and silently stopped at depth six. .git is pruned — its objects
  # have no business being group-readable.
  shell("find . -path ./.git -prune -o -type d -exec chmod o+rx,g+rx {} + -o -type f -exec chmod o+r,g+r {} +")
end

desc "Build the gem and set the permissions"
task build: :permissions

# Files, title and markup come from .yardopts, so `yard doc`, `yard server`
# and this task all build the same site. The output, doc/, is git-ignored.
YARD::Rake::YardocTask.new(:yard)

desc "Generate the YARD documentation into doc/ and open doc/index.html"
task doc: :yard do
  index = File.expand_path("doc/index.html", __dir__)
  opener = RUBY_PLATFORM.include?("darwin") ? "open" : "xdg-open"

  # An open that fails, on a headless box or in CI, is not a failed build:
  # the docs are on disk either way.
  system(opener, index) || warn("Documentation written to #{index}")
end

RSpec::Core::RakeTask.new(:spec)

task default: :spec
