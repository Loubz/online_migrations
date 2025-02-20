# frozen_string_literal: true

module MinitestHelpers
  def assert_raises_with_message(exception_class, message, &block)
    error = assert_raises(exception_class, &block)
    assert_match message, error.message
  end

  def migrate(migration, direction: :up)
    connection = ActiveRecord::Base.connection

    if OnlineMigrations::Utils.ar_version >= 7.1
      ActiveRecord::SchemaMigration.new(connection).delete_all_versions
    else
      ActiveRecord::SchemaMigration.delete_all
    end

    migration.version ||= 1

    if direction == :down
      if OnlineMigrations::Utils.ar_version >= 7.1
        ActiveRecord::SchemaMigration.new(connection).create_version(migration.version)
      else
        ActiveRecord::SchemaMigration.create!(version: migration.version)
      end
    end

    args =
      if OnlineMigrations::Utils.ar_version >= 7.1
        # [ActiveRecord::SchemaMigration, ActiveRecord::InternalMetadata]
        [ActiveRecord::SchemaMigration.new(connection), ActiveRecord::InternalMetadata.new(connection)]
      elsif OnlineMigrations::Utils.ar_version >= 6
        [ActiveRecord::SchemaMigration]
      else
        []
      end
    ActiveRecord::Migrator.new(direction, [migration], *args).migrate
    true
  end

  def assert_safe(migration, direction: nil)
    if direction
      assert migrate(migration, direction: direction)
    else
      assert migrate(migration, direction: :up)
      assert migrate(migration, direction: :down)
    end
  end

  def assert_unsafe(migration, message = nil, **options)
    error = assert_raises(StandardError) { migrate(migration, **options) }
    assert_instance_of OnlineMigrations::UnsafeMigration, error.cause

    puts error.message if ENV["VERBOSE"]
    assert_match(message, error.message) if message
  end

  def assert_raises_in_transaction(&block)
    error = assert_raises(RuntimeError) do
      ActiveRecord::Base.transaction(&block)
    end
    assert_match "cannot run inside a transaction", error.message
  end

  def track_queries(&block)
    queries = []
    query_cb = ->(*, payload) { queries << payload[:sql] unless ["TRANSACTION"].include?(payload[:name]) }
    ActiveSupport::Notifications.subscribed(query_cb, "sql.active_record", &block)
    queries
  end

  def assert_sql(*patterns_to_match, &block)
    queries = track_queries(&block)

    failed_patterns = []
    patterns_to_match.each do |pattern|
      pattern = pattern.downcase
      failed_patterns << pattern if queries.none? { |sql| sql.downcase.include?(pattern) }
    end
    assert_empty failed_patterns,
      "Query pattern(s) #{failed_patterns.map(&:inspect).join(', ')} not found.#{queries.empty? ? '' : "\nQueries:\n#{queries.join("\n")}"}"
  end

  def refute_sql(*patterns_to_match, &block)
    queries = track_queries(&block)

    failed_patterns = []
    patterns_to_match.each do |pattern|
      pattern = pattern.downcase
      failed_patterns << pattern if queries.any? { |sql| sql.downcase.include?(pattern) }
    end
    assert_empty failed_patterns,
      "Query pattern(s) #{failed_patterns.map(&:inspect).join(', ')} found.#{queries.empty? ? '' : "\nQueries:\n#{queries.join("\n")}"}"
  end

  def with_target_version(version)
    prev = OnlineMigrations.config.target_version
    OnlineMigrations.config.target_version = version
    yield
  ensure
    OnlineMigrations.config.target_version = prev
  end

  def with_postgres(major_version, &block)
    pg_connection = ActiveRecord::Base.connection.raw_connection
    pg_connection.stub(:server_version, major_version * 1_00_00, &block)
  end

  def ar_version
    OnlineMigrations::Utils.ar_version
  end

  def migration_parent_string
    OnlineMigrations::Utils.migration_parent_string
  end

  def model_parent_string
    OnlineMigrations::Utils.model_parent_string
  end

  def supports_multiple_dbs?
    OnlineMigrations::Utils.supports_multiple_dbs?
  end
end

Minitest::Test.class_eval do
  include MinitestHelpers
  alias_method :assert_not, :refute
end
