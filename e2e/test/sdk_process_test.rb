require "test_helper"
require "rbconfig"
require "support/sdk_process"

class SDKProcessTest < Minitest::Test
  def test_private_stdin_and_incremental_facts_are_available_before_exit
    script = <<~RUBY
      require "json"
      input = JSON.parse(STDIN.read)
      STDOUT.sync = true
      puts JSON.generate(event: "ready", argc: ARGV.length, value: input.fetch("value"))
      sleep 0.1
      puts JSON.generate(event: "result", completed: true)
    RUBY
    process = E2E::SDKProcess.new([RbConfig.ruby, "-e", script], { value: "private-input" }, timeout: 2)
    ready = process.wait_for("ready")
    assert_equal 0, ready.fetch("argc")
    assert_equal "private-input", ready.fetch("value")
    assert_equal({ "event" => "result", "completed" => true }, process.finish)
    assert_equal 2, process.records.length
  ensure
    process&.close
  end

  def test_driver_failure_redacts_registered_credentials
    secret = E2E::SecretHygiene.register("synthetic-sdk-secret")
    process = E2E::SDKProcess.new([RbConfig.ruby, "-e", "warn STDIN.read; exit 7"], { credential: secret }, timeout: 2)
    error = assert_raises(RuntimeError) { process.finish }
    assert_includes error.message, "exited 7"
    assert_includes error.message, "[REDACTED]"
    refute_includes error.message, secret
  ensure
    process&.close
  end

  def test_a_missing_readiness_fact_is_bounded_by_the_child_deadline
    process = E2E::SDKProcess.new([RbConfig.ruby, "-e", "STDIN.read; sleep 60"], {}, timeout: 0.5)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(Timeout::Error) { process.wait_for("ready") }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
  ensure
    process&.close
  end
end
