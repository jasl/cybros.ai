require "minitest/autorun"
require "minitest/mock"
require "active_record"
require "active_record/database_configurations"
require_relative "../../app/services/model_invocations/wake"
require_relative "../../app/services/model_runner/host"

# No database is opened: this pins the raw connection's libpq configuration
# boundary separately from Active Record's connection pool and Rails fixtures.
class ModelRunnerListenTest < Minitest::Test
  def test_absent_rails_options_leave_libpq_environment_defaults_available
    captured = listen_with(database: "test_primary")

    assert_equal({ dbname: "test_primary" }, captured)
    refute_includes PG::Connection.parse_connect_args(captured), "host=''"
    refute_includes PG::Connection.parse_connect_args(captured), "password=''"
  end

  def test_explicit_rails_options_are_preserved_for_the_dedicated_listener
    captured = listen_with(database: "test_primary", host: "postgres.example", port: 6543,
      username: "test_user", password: "test-password")

    assert_equal({ dbname: "test_primary", host: "postgres.example", port: 6543,
      user: "test_user", password: "test-password" }, captured)
  end

  private

    def listen_with(configuration)
      db_config = ActiveRecord::DatabaseConfigurations::HashConfig.new("test", "primary", configuration)
      statements, closed, captured = [], false, nil
      connection = Object.new
      connection.define_singleton_method(:exec) { |sql| statements << sql }
      connection.define_singleton_method(:close) { closed = true }
      connect = ->(**options) { captured = options; connection }
      host = ModelRunner::Host.new(logger: nil)

      ActiveRecord::Base.stub(:connection_db_config, db_config) do
        PG.stub(:connect, connect) do
          host.send(:with_listen_connection) { |received| assert_same connection, received }
        end
      end
      assert_equal ["LISTEN #{ModelInvocations::Wake::NOTIFY_CHANNEL}"], statements
      assert closed
      captured
    end
end
