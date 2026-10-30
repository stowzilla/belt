# frozen_string_literal: true

module Belt
  # Base class for data migrations in `db/migrate/<timestamp>_<name>.rb`.
  #
  #   # db/migrate/20261030120000_index_usernames.rb
  #   class IndexUsernames < Belt::Migration
  #     def up
  #       PoshNosh::MatchStore.new.index_usernames!
  #     end
  #   end
  #
  # `belt deploy <env>` runs pending migrations after terraform apply, and
  # `belt db:migrate <env>` runs them by hand. Each version runs once per
  # environment (nested envs included); applied versions are recorded in SSM.
  #
  # Migrations touch live data, possibly while a new GSI is still backfilling
  # or the previous code is still serving requests, so `up` must be
  # idempotent (safe to re-run after a partial failure) and batch-safe (page
  # through the base table rather than querying a GSI it is populating).
  class Migration
    attr_reader :version, :name

    def initialize(version:, name:)
      @version = version
      @name = name
    end

    def up
      raise NotImplementedError, "#{self.class.name} must define #up"
    end

    def say(message)
      puts "    #{message}"
    end
  end
end
