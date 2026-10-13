require_relative "test_helper"

class CLITest < OperatorTest
  def test_login_verifies_the_operator_and_only_persists_the_api_session
    @transport.answer(201, { "token" => TOKEN, "token_type" => "Bearer", "session" => SESSION })
    @transport.answer(200, profile)

    assert_equal 0, run_cli("login", "--url", "http://localhost:3000/", "--email", "operator@example.test",
      "--password-stdin", input: "synthetic-password\n")
    assert_equal "http://localhost:3000", @config.read.base_url
    assert_equal TOKEN, @config.read.token
    assert_equal 0o700, File.stat(@home).mode & 0o777
    assert_equal 0o600, File.stat(File.join(@home, "session.json")).mode & 0o777
    refute_includes @output.string, TOKEN
    refute_includes @output.string, "synthetic-password"
    refute_includes File.read(File.join(@home, "session.json")), "synthetic-password"
    assert_equal true, output.fetch("connected")
    assert_equal "/api/v1/session", @transport.requests.first.fetch(:path)
    assert_equal "synthetic-password", @transport.requests.first.fetch(:body).fetch("password")
    assert_equal TOKEN, @transport.requests.last.fetch(:credential)
  end

  def test_non_admin_login_revokes_the_new_session_and_saves_nothing
    @transport.answer(201, { "token" => TOKEN, "token_type" => "Bearer", "session" => SESSION })
    @transport.answer(200, profile(role: "member"))
    @transport.answer(200, { "revoked" => true })

    assert_equal 1, run_cli("login", "--url", "http://localhost:3000", "--email", "member@example.test",
      "--password-stdin", input: "synthetic-password\n")
    refute @config.present?
    assert_equal :delete, @transport.requests.last.fetch(:method)
    assert_includes @error.string, "administrator"
  end

  def test_login_does_not_overwrite_an_existing_connection
    saved_session
    assert_equal 1, run_cli("login", "--url", "http://another.test", "--email", "operator@example.test",
      "--password-stdin", input: "synthetic-password\n")
    assert_empty @transport.requests
    assert_equal "http://localhost:3000", @config.read.base_url
  end

  def test_secrets_require_explicit_stdin_and_never_become_arguments
    assert_equal 2, run_cli("login", "--url", "http://localhost:3000", "--email", "operator@example.test",
      input: "synthetic-password\n")
    assert_empty @transport.requests
    assert_equal 2, run_cli("login", "--password=synthetic-password")
    refute_includes @error.string, "synthetic-password"
  end

  def test_status_uses_the_saved_session_but_never_prints_it
    saved_session
    @transport.answer(200, profile)
    @transport.answer(200, { "session" => SESSION })
    assert_equal 0, run_cli("status")
    assert_equal "human", output.fetch("member").fetch("kind")
    refute_includes @output.string, TOKEN
  end

  def test_models_filters_and_renders_nested_pricing_as_json
    saved_session
    @transport.answer(200, { "models" => [{ "ref" => "example/chat", "provider" => "example",
      "workload" => "text_generation", "visible" => true, "available" => true,
      "pricing" => { "state" => "priced", "unit" => "USD", "input_per_mtok" => "1" } }] })
    assert_equal 0, run_cli("models", "--available", "--workload", "text_generation")
    assert_equal "USD", output.fetch("models").first.fetch("pricing").fetch("unit")
    assert_equal({ "workload" => "text_generation", "available" => "true" }, @transport.requests.first.fetch(:params))
    assert_equal "/api/v1/admin/models", @transport.requests.first.fetch(:path)
  end

  def test_models_without_a_filter_keeps_unavailable_admin_rows
    saved_session
    @transport.answer(200, { "models" => [{ "ref" => "example/chat", "provider" => "example",
      "workload" => "text_generation", "visible" => true, "available" => false, "unavailable_reason" => "missing_credential",
      "pricing" => { "state" => "priced", "unit" => "USD" } }] })

    assert_equal 0, run_cli("models")
    row = output.fetch("models").first
    refute row.fetch("available")
    assert_equal "missing_credential", row.fetch("unavailable_reason")
    assert_nil @transport.requests.first.fetch(:params)
    assert_equal "/api/v1/admin/models", @transport.requests.first.fetch(:path)
  end

  def test_hidden_models_remain_inspectable_with_their_pricing
    saved_session
    @transport.answer(200, { "models" => [{ "ref" => "example/chat", "provider" => "example",
      "workload" => "text_generation", "visible" => false, "available" => false, "unavailable_reason" => "model_hidden",
      "pricing" => { "state" => "priced", "unit" => "USD", "input_per_mtok" => "1.25" } }] })

    assert_equal 0, run_cli("models")
    row = output.fetch("models").first
    refute row.fetch("visible")
    refute row.fetch("available")
    assert_equal "model_hidden", row.fetch("unavailable_reason")
    assert_equal "1.25", row.fetch("pricing").fetch("input_per_mtok")
  end

  def test_model_hide_and_unhide_read_the_policy_version_without_changing_lane_enablement
    saved_session
    @transport.answer(200, { "model_provider" => lane(version: 7) })
    @transport.answer(200, { "model_provider" => lane(version: 8) })
    assert_equal 0, run_cli("model", "hide", "example/vendor/chat")
    assert_equal 8, output.fetch("model_provider").fetch("lock_version")
    @transport.answer(200, { "model_provider" => lane(version: 8) })
    @transport.answer(200, { "model_provider" => lane(version: 9) })
    assert_equal 0, run_cli("model", "unhide", "example/vendor/chat")
    assert_equal 9, output.fetch("model_provider").fetch("lock_version")
    refute output.fetch("model_provider").fetch("enabled")
    assert_equal ["/api/v1/admin/model_providers/example", "/api/v1/admin/model_providers/example/model_visibility"] * 2,
      @transport.requests.map { |row| row.fetch(:path) }
    assert_equal [
      { "command" => { "model" => "example/vendor/chat", "visible" => false, "expected_lock_version" => 7 } },
      { "command" => { "model" => "example/vendor/chat", "visible" => true, "expected_lock_version" => 8 } },
    ], @transport.requests.select { |row| row.fetch(:method) == :put }.map { |row| row.fetch(:body) }
  end

  def test_model_hide_initializes_visibility_without_enabling_or_configuring_the_provider
    saved_session
    @transport.answer(200, { "model_provider" => lane.merge("configured" => false) })
    @transport.answer(200, { "model_provider" => lane(version: 0).merge("configured" => false) })

    assert_equal 0, run_cli("model", "hide", "example/chat")
    assert_equal 0, output.fetch("model_provider").fetch("lock_version")
    refute output.fetch("model_provider").fetch("enabled")
    refute output.fetch("model_provider").fetch("configured")
    assert_equal ["/api/v1/admin/model_providers/example", "/api/v1/admin/model_providers/example/model_visibility"],
      @transport.requests.map { |row| row.fetch(:path) }
    assert_equal({ "command" => { "model" => "example/chat", "visible" => false, "expected_lock_version" => nil } },
      @transport.requests.last.fetch(:body))
  end

  def test_model_visibility_rejects_unknown_models_and_stale_versions_without_retrying
    saved_session
    @transport.answer(200, { "model_provider" => lane })
    @transport.answer(404, { "error" => { "code" => "not_found" } })
    assert_equal 1, run_cli("model", "hide", "example/unknown-model")
    assert_equal 2, @transport.requests.length
    assert_nil @transport.requests.last.fetch(:body).fetch("command").fetch("expected_lock_version")
    assert_empty @output.string
    assert_includes @error.string, "not_found"

    @transport.answer(200, { "model_provider" => lane(version: 7) })
    @transport.answer(409, { "error" => { "code" => "stale_object" } })
    assert_equal 1, run_cli("model", "unhide", "example/chat")
    assert_equal 4, @transport.requests.length
    assert_includes @error.string, "stale_object"
  end

  def test_model_visibility_requires_a_full_reference_and_supported_command
    assert_equal 2, run_cli("model", "hide")
    assert_equal 2, run_cli("model", "hide", "chat")
    assert_equal 2, run_cli("model", "unhide", "example/")
    assert_equal 2, run_cli("model", "show", "example/chat")
    assert_empty @transport.requests
  end

  def test_enable_reads_current_version_and_never_retries_a_conflict
    saved_session
    @transport.answer(200, { "model_provider" => lane(version: 7) })
    @transport.answer(409, { "error" => { "code" => "stale_object", "message" => "synthetic-secret" } })
    assert_equal 1, run_cli("provider", "enable", "example")
    assert_equal 2, @transport.requests.length
    assert_equal "/api/v1/admin/model_providers/example", @transport.requests.first.fetch(:path)
    assert_equal({ "command" => { "enabled" => true, "expected_lock_version" => 7 } }, @transport.requests.last.fetch(:body))
    assert_includes @error.string, "stale_object"
    refute_includes @error.string, "synthetic-secret"
  end

  def test_enable_a_lane_without_a_policy_and_disable_an_existing_lane
    saved_session
    @transport.answer(200, { "model_provider" => lane })
    @transport.answer(200, { "model_provider" => lane(version: 0, enabled: true) })
    assert_equal 0, run_cli("provider", "enable", "example")
    assert_nil @transport.requests.last.fetch(:body).fetch("command").fetch("expected_lock_version")
    assert_equal true, output.fetch("model_provider").fetch("enabled")
    @transport.answer(200, { "model_provider" => lane(version: 0, enabled: true) })
    @transport.answer(200, { "model_provider" => lane(version: 1) })
    assert_equal 0, run_cli("provider", "disable", "example")
    assert_equal false, @transport.requests.last.fetch(:body).fetch("command").fetch("enabled")
  end

  def test_key_installation_keeps_the_secret_out_of_output_and_local_storage
    saved_session
    @transport.answer(200, { "model_provider" => lane })
    assert_equal 0, run_cli("provider", "key", "set", "example", "--stdin", input: "synthetic-provider-key\n")
    assert_equal "/api/v1/admin/model_providers/example/api_key", @transport.requests.last.fetch(:path)
    assert_equal "synthetic-provider-key", @transport.requests.last.fetch(:body).fetch("command").fetch("api_key")
    refute_includes @output.string, "synthetic-provider-key"
    refute_includes File.read(File.join(@home, "session.json")), "synthetic-provider-key"
    @transport.answer(200, { "model_provider" => lane })
    assert_equal 0, run_cli("provider", "key", "clear", "example")
    assert_equal :delete, @transport.requests.last.fetch(:method)
  end

  def test_cost_unit_is_an_explicit_operator_choice
    saved_session
    @transport.answer(200, { "account" => { "cost_unit" => "USD" } })
    assert_equal 0, run_cli("account", "cost-unit", "USD")
    assert_equal({ "account" => { "cost_unit" => "USD" } }, output)
    assert_equal "/api/v1/admin/account/cost_unit", @transport.requests.last.fetch(:path)
  end

  def test_logout_retains_a_session_on_network_failure_and_local_logout_is_explicit
    saved_session
    @transport.answer(503, nil)
    assert_equal 1, run_cli("logout")
    assert @config.present?
    assert_equal 0, run_cli("logout", "--local")
    refute @config.present?
    assert_equal true, output.fetch("local_only")
  end

  def test_logout_revokes_or_forgets_an_expired_session
    [200, 401].each do |status|
      saved_session
      @transport.answer(status, status == 200 ? { "revoked" => true } : { "error" => { "code" => "unauthorized" } })
      assert_equal 0, run_cli("logout")
      refute @config.present?
    end
  end

  def test_invalid_commands_and_unconfigured_use_fail_without_http
    assert_equal 0, run_cli("--help")
    assert_includes @output.string, "Usage: cmctl"
    assert_equal 1, run_cli("providers")
    assert_equal 2, run_cli("provider", "enable")
    assert_equal 2, run_cli("account", "cost-unit")
    assert_equal 2, run_cli("unknown")
    assert_empty @transport.requests
  end
end
