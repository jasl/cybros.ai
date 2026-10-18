require "minitest/autorun"
require "json"
require "open3"
require "rbconfig"

class DatabaseNamesTest < Minitest::Test
  # Read the real ERB without booting Rails or loading the operator's dotenv files.
  RENDER = <<~RUBY.freeze
    require "erb"
    require "json"
    require "yaml"
    puts JSON.generate(YAML.safe_load(ERB.new(File.read(ARGV.fetch(0))).result, aliases: true))
  RUBY

  def test_development_overrides_do_not_change_test_databases
    configuration = render_configuration(
      "RAILS_APP_DB_NAME" => "local_primary",
      "RAILS_QUEUE_DB_NAME" => "local_queue",
      "RAILS_CABLE_DB_NAME" => "local_cable"
    )

    assert_equal "local_primary", configuration.dig("development", "primary", "database")
    assert_equal "local_queue", configuration.dig("development", "queue", "database")
    assert_equal "local_cable", configuration.dig("development", "cable", "database")
    assert_equal "cybros_nexus_test", configuration.dig("test", "primary", "database")
    assert_equal "cybros_nexus_cable_test", configuration.dig("test", "cable", "database")
  end

  def test_test_overrides_are_independent_of_development_and_production
    configuration = render_configuration(
      "RAILS_APP_DB_NAME" => "local_primary",
      "RAILS_CABLE_DB_NAME" => "local_cable",
      "RAILS_TEST_APP_DB_NAME" => "isolated_primary",
      "RAILS_TEST_CABLE_DB_NAME" => "isolated_cable"
    )

    assert_equal "isolated_primary", configuration.dig("test", "primary", "database")
    assert_equal "isolated_cable", configuration.dig("test", "cable", "database")
    %w[development production].each do |environment|
      assert_equal "local_primary", configuration.dig(environment, "primary", "database")
      assert_equal "local_cable", configuration.dig(environment, "cable", "database")
    end
  end

  def test_url_connections_use_the_same_independent_names
    configuration = render_configuration(
      "RAILS_DB_URL_BASE" => "postgres://localhost:5432",
      "RAILS_APP_DB_NAME" => "local_primary",
      "RAILS_CABLE_DB_NAME" => "local_cable",
      "RAILS_TEST_APP_DB_NAME" => "isolated_primary",
      "RAILS_TEST_CABLE_DB_NAME" => "isolated_cable"
    )

    assert_equal "postgres://localhost:5432/isolated_primary", configuration.dig("test", "primary", "url")
    assert_equal "postgres://localhost:5432/isolated_cable", configuration.dig("test", "cable", "url")
    %w[development production].each do |environment|
      assert_equal "postgres://localhost:5432/local_primary", configuration.dig(environment, "primary", "url")
      assert_equal "postgres://localhost:5432/local_cable", configuration.dig(environment, "cable", "url")
    end
  end

  def test_default_pool_keeps_ten_connections_with_one_request_thread
    configuration = render_configuration("RAILS_MAX_THREADS" => "1")

    %w[development test production].each do |environment|
      configuration.fetch(environment).each_value do |database|
        assert_equal 10, database.fetch("pool")
      end
    end
  end

  def test_automatic_pool_still_covers_larger_request_thread_counts
    configuration = render_configuration("RAILS_MAX_THREADS" => "12")

    assert_equal 12, configuration.dig("production", "primary", "pool")
  end

  def test_explicit_pool_overrides_automatic_sizing
    configuration = render_configuration("RAILS_MAX_THREADS" => "12", "RAILS_DB_POOL" => "16")

    assert_equal 16, configuration.dig("production", "primary", "pool")
  end

  private

    def render_configuration(variables)
      stdout, stderr, status = Open3.capture3(
        variables, RbConfig.ruby, "-e", RENDER,
        File.expand_path("../../config/database.yml", __dir__),
        unsetenv_others: true
      )
      assert status.success?, stderr
      JSON.parse(stdout)
    end
end
