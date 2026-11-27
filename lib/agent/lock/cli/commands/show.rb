# frozen_string_literal: true

require "dry/cli/ui"
require "shellwords"
require "socket"
require_relative "base"
require_relative "../../store/redis_index"

module Agent
  module Lock
    module CLI
      module Commands
        # Redis only. These commands read every repository in one Redis, so
        # `--dir` would name a checkout they never open, and the file store
        # has nothing for them to read.
        #
        # @abstract
        class Show < Base
          include Dry::CLI::UI

          # @param subclass [Class<Show>]
          # @return [void]
          def self.inherited(subclass)
            super
            subclass.option :redis_url, type: :string, aliases: ["-u"],
                                        desc: "The one Redis to use, with no fallback " \
                                              "(env: AGENT_LOCK_REDIS_URL, else REDIS_URL)"
          end

          private

          # @param options [Hash]
          # @return [Store::RedisIndex]
          # @raise [Dry::CLI::Error] when `--redis-url` is present and empty
          # @raise [Store::Unreachable] when Redis does not answer
          def index(options)
            url = options[:redis_url]&.strip
            raise Dry::CLI::Error, "--redis-url is empty" if url && url.empty?

            Store::RedisIndex.open(url || Store.named_redis_url)
          end

          # @param rows [Array<Array<#to_s>>]
          # @param header [Array<String>]
          # @param empty [String] printed instead of a header when there are no rows
          # @return [void]
          def table(rows, header:, empty:)
            return say(empty) if rows.empty?

            ui.table(rows, header: header)
          end

          # The command that drops this lock. `break`, because `release` only
          # works for the session that holds it. The branch is a comment, so
          # the line still pastes: two branches can hold the same scope.
          #
          # @param record [Record]
          # @return [String]
          def release_command(record)
            branch = record.branch || "detached"
            host = record.host && record.host != Socket.gethostname ? " on #{record.host}" : ""
            "#{program} break --dir #{Shellwords.shellescape(record.tree)} " \
              "#{Shellwords.shellescape(record.scope)}  # #{branch}#{host}"
          end

          # @param record [Record]
          # @return [String]
          def held_for(record)
            Dry::CLI::UI::Duration.format(Time.now.utc - Time.parse(record.created_at))
          rescue ArgumentError, TypeError
            "unknown"
          end
        end

        # `alock show repos`.
        class ShowRepos < Show
          desc "Redis: every repository, how many locks it holds, and the memory they use"

          example ["", "-u redis://127.0.0.1:6379/0"]

          # @param options [Hash] `:redis_url`
          # @return [void]
          def call(**options)
            rows = index(options).repos.map { |repo| [repo.namespace, repo.count, Store::RedisIndex.format_bytes(repo.bytes)] }
            table(rows, header: %w[Namespace Locks Memory], empty: "No locks in Redis.")
          end
        end

        # `alock show repo owner/name`.
        class ShowRepo < Show
          desc "Redis: the locks held on one GitHub repository"

          argument :repo, required: true, desc: "GitHub repository as owner/name"

          example ["kigster/laser-cutter"]

          # @param repo [String]
          # @param options [Hash] `:redis_url`
          # @return [void]
          def call(repo:, **options)
            locks = index(options).locks(repo)
            rows = locks.map { |lock| row(lock.record) }
            table(rows, header: %w[Scope Holder Held Alive Release], empty: "No locks for #{repo}.")
          end

          private

          # @param record [Record]
          # @return [Array<String>]
          def row(record)
            [record.scope, record.agent_id, held_for(record), Store::RedisIndex.alive(record), release_command(record)]
          end
        end
      end
    end
  end
end
