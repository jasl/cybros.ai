require_relative "test_helper"

class ModelAvailabilityCLITest < OperatorTest
  def test_invalidate_and_restore_read_the_current_version_without_enabling_the_provider
    saved_session
    @transport.answer(200, { "model_provider" => lane(version: 7) })
    @transport.answer(200, { "model_provider" => lane(version: 8) })
    assert_equal 0, run_cli("model", "invalidate", "example/vendor/chat")
    assert_equal 8, output.fetch("model_provider").fetch("lock_version")
    @transport.answer(200, { "model_provider" => lane(version: 8) })
    @transport.answer(200, { "model_provider" => lane(version: 9) })
    assert_equal 0, run_cli("model", "restore", "example/vendor/chat")
    refute output.fetch("model_provider").fetch("enabled")
    assert_equal ["/api/v1/admin/model_providers/example", "/api/v1/admin/model_providers/example/model_availability"] * 2,
      @transport.requests.map { |row| row.fetch(:path) }
    assert_equal [
      { "command" => { "model" => "example/vendor/chat", "available" => false, "expected_lock_version" => 7 } },
      { "command" => { "model" => "example/vendor/chat", "available" => true, "expected_lock_version" => 8 } },
    ], @transport.requests.select { |row| row.fetch(:method) == :put }.map { |row| row.fetch(:body) }
  end

  def test_probe_keeps_the_result_and_policy_update_separate_and_never_retries_a_stale_update
    saved_session
    @transport.answer(200, { "model_provider" => lane(version: 7, enabled: true) })
    @transport.answer(200, { "model_provider" => lane(version: 8, enabled: true),
      "model_test" => { "outcome" => "succeeded", "duration_ms" => 42, "http_status" => 200, "availability_update" => "stale" } })

    assert_equal 0, run_cli("model", "test", "example/vendor/chat")
    assert_equal "succeeded", output.fetch("model_test").fetch("outcome")
    assert_equal "stale", output.fetch("model_test").fetch("availability_update")
    assert_equal 8, output.fetch("model_provider").fetch("lock_version")
    assert_equal 2, @transport.requests.length
    assert_equal :post, @transport.requests.last.fetch(:method)
    assert_equal "/api/v1/admin/model_providers/example/model_test", @transport.requests.last.fetch(:path)
    assert_equal({ "command" => { "model" => "example/vendor/chat", "expected_lock_version" => 7 } },
      @transport.requests.last.fetch(:body))
  end

  def test_probe_failures_are_reported_as_the_server_observed_them
    saved_session
    @transport.answer(200, { "model_provider" => lane(version: 7, enabled: true) })
    @transport.answer(200, { "model_provider" => lane(version: 7, enabled: true),
      "model_test" => { "outcome" => "timed_out", "duration_ms" => 30_000, "http_status" => nil, "availability_update" => "unchanged" } })

    assert_equal 0, run_cli("model", "test", "example/chat")
    assert_equal "timed_out", output.fetch("model_test").fetch("outcome")
    assert_equal "unchanged", output.fetch("model_test").fetch("availability_update")
    assert_nil output.fetch("model_test").fetch("http_status")
    assert_equal 2, @transport.requests.length
  end

  def test_availability_conflicts_and_missing_policies_are_not_retried
    saved_session
    @transport.answer(200, { "model_provider" => lane })
    @transport.answer(404, { "error" => { "code" => "not_found" } })
    assert_equal 1, run_cli("model", "invalidate", "example/chat")
    assert_nil @transport.requests.last.fetch(:body).dig("command", "expected_lock_version")
    assert_includes @error.string, "not_found"

    @transport.answer(200, { "model_provider" => lane(version: 7) })
    @transport.answer(409, { "error" => { "code" => "stale_object" } })
    assert_equal 1, run_cli("model", "restore", "example/chat")
    assert_equal 4, @transport.requests.length
    assert_includes @error.string, "stale_object"
  end

  def test_each_command_requires_a_full_model_reference
    assert_equal 2, run_cli("model", "test")
    assert_equal 2, run_cli("model", "invalidate", "chat")
    assert_equal 2, run_cli("model", "restore", "example/")
    assert_empty @transport.requests
  end
end
