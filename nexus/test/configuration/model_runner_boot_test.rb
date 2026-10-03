require "test_helper"

# bin/model_runner is the one entrypoint the unit suite never loads. Booting the script against the
# test app, with the host's run loop stubbed at its first real step, resolves every name the script
# calls and installs the boot shim for real.
class ModelRunnerBootTest < ActiveSupport::TestCase
  test "bin/model_runner boots through the Rails shim to the host" do
    host = Minitest::Mock.new
    host.expect(:run, nil)
    pool = ENV["RAILS_DB_POOL"]

    ModelRunner::Host.stub(:new, host) do
      load Rails.root.join("bin/model_runner")
    end

    host.verify
    names = Nexus::Application.initializers.map(&:name)
    assert_includes names, "model_runner.configure_logger"
    assert_includes names, "model_runner.broadcast_logger"
  ensure
    pool.nil? ? ENV.delete("RAILS_DB_POOL") : ENV["RAILS_DB_POOL"] = pool
  end
end
