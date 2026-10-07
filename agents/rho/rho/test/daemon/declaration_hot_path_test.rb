require "support/daemon_run_helpers"

class DaemonDeclarationHotPathTest < Minitest::Test
  include RhoTest::DaemonRunHelpers

  def test_remote_open_and_say_refresh_once_before_assembling_the_turn
    api = kernel_api(executors: [NexusDoubles.remote_runner("remote-a")])
    daemon = member_ready(boot(config: catalog_config, realtime_factory: ->(*) { nil }), api)
    before = api.requests.length

    code, answer = open(daemon, prompt: "First turn", model: "dev/test", default_runner_executor_public_id: "remote-a")

    assert_equal "201", code, answer.inspect
    assert_turn_refresh(api.requests.drop(before))
    assert_equal 1, api.configuration_declarations.length
    id = answer.dig("conversation", "public_id")
    before = api.requests.length

    response = request(daemon, :post, "/say", token: bearer(daemon),
      body: { public_id: id, text: "Next turn", wait: false })

    assert_equal "200", response.code, response.body
    assert_turn_refresh(api.requests.drop(before))
    assert_equal 1, api.configuration_declarations.length, "unchanged discovery skips the profile write"

    api.reannounce_executor(NexusDoubles.remote_runner("remote-a", tools: [NexusDoubles.served_tool("new_read")]))
    before = api.requests.length
    response = request(daemon, :post, "/say", token: bearer(daemon),
      body: { public_id: id, text: "Use the new tool", code_mode: false, wait: false })

    assert_equal "200", response.code, response.body
    assert_turn_refresh(api.requests.drop(before))
    assert_includes api.conversation_inputs.last.dig("input", "tool_names"), "new_read"
    refute_includes api.conversation_inputs.last.dig("input", "tool_names"), "slow_read"
    assert_equal 1, api.configuration_declarations.length, "Runner schemas are refreshed without copying them into the profile"
  end

  def test_refused_changed_declaration_blocks_assembly_and_input_and_is_retried
    api = kernel_api(executors: [NexusDoubles.remote_runner("remote-a")])
    daemon = member_ready(boot(config: catalog_config, realtime_factory: ->(*) { nil }), api)
    code, answer = open(daemon, prompt: "First turn", model: "dev/test", default_runner_executor_public_id: "remote-a")
    assert_equal "201", code, answer.inspect
    id = answer.dig("conversation", "public_id")
    submitted = api.conversation_inputs.length
    declared = api.configuration_declarations.length
    api.reannounce_executor(NexusDoubles.remote_runner("remote-b"))
    api.instance_variable_set(:@configuration, CybrosAgent::Response.new(status: 422, headers: {},
      body: { "error" => { "code" => "validation_failed", "message" => "Profile refused" } }))
    before = api.requests.length

    refused = request(daemon, :post, "/say", token: bearer(daemon),
      body: { public_id: id, text: "Refused turn", wait: false })

    assert_equal "422", refused.code, refused.body
    assert_equal "validation_failed", JSON.parse(refused.body).dig("error", "code")
    assert_equal submitted, api.conversation_inputs.length
    assert_equal declared + 1, api.configuration_declarations.length
    paths = api.requests.drop(before).map(&:first)
    assert_equal 1, paths.count("/agent_api/v1/executors")
    assert_equal 1, paths.count("/agent_api/v1/profile/agents")
    refute_includes paths, "/agent_api/v1/tools/assembly"

    api.instance_variable_set(:@configuration, :accept)
    before = api.requests.length
    recovered = request(daemon, :post, "/say", token: bearer(daemon),
      body: { public_id: id, text: "Retry turn", wait: false })

    assert_equal "200", recovered.code, recovered.body
    assert_turn_refresh(api.requests.drop(before))
    assert_equal submitted + 1, api.conversation_inputs.length
    assert_equal declared + 2, api.configuration_declarations.length
    assert_equal api.configuration_declarations[-2], api.configuration_declarations[-1], "refused bytes were not recorded as accepted"
  end

  # A turn needs names for the editor policy. Registry registration already
  # admitted these tools; projecting their names must not lower their schemas.
  def test_turn_names_keep_agent_and_anchor_scope_without_schema_lowering
    fixture = Module.new do
      const_set(:NAME, "test.turn_names")
      define_singleton_method(:register) do |api|
        { agent: %w[zeta skill summarize_history files_bytes alpha], runner: %w[runner_only alpha] }.each do |address, names|
          names.each do |name|
            tool = Class.new do
              const_set(:NAME, name)
              const_set(:DESCRIPTION, "The #{name} tool")
              const_set(:SCHEMA, { "type" => "object", "properties" => {} })
              const_set(:EFFECT_PROFILE, Rho::Runner::Tools::Read::EFFECT_PROFILE)
              define_method(:initialize) { |env:| }
              define_method(:call) { |_arguments| Rho::Runner::Result.ok(name) }
            end
            api.register_tool(tool, serves: address)
          end
        end
      end
    end
    loaded = Rho::Extensions.load(host: RhoTest.host, extensions: [fixture])
    assert_empty loaded.failures
    servers = Object.new
    servers.define_singleton_method(:announcement_for) do |anchor|
      anchor == "own" ? [NexusDoubles.served_tool("mcp__editor__query")] : []
    end
    servers.define_singleton_method(:names_for) { |anchor| anchor == "own" ? ["mcp__editor__query"] : [] }
    followers = Rho::Daemon::HostFollowers.allocate
    followers.instance_variable_set(:@loaded, loaded)
    followers.instance_variable_set(:@environments, Data.define(:servers).new(servers))
    followers.instance_variable_set(:@adaptations, Rho::Adaptations.load(RhoTest.host.config, home: RhoTest.host.home))
    binding = Data.define(:anchor).new("own")
    lowered = 0
    trace = TracePoint.new(:call) { |event| lowered += 1 if event.method_id == :function_entry }

    surface = trace.enable { followers.send(:turn_surface, nil, nil, binding: binding) }

    assert_equal %w[alpha mcp__editor__query zeta], surface.own_names
    assert_equal 0, lowered, "name selection must not render full function schemas"
    assert_equal %w[alpha zeta], followers.send(:turn_surface, nil, nil).own_names
    assert_equal %w[alpha zeta], followers.send(:turn_surface, nil, nil, binding: binding.with(anchor: "foreign")).own_names
  end

  def test_malformed_environment_and_attachment_shapes_keep_the_boundary_refusal
    api = kernel_api
    daemon = member_ready(boot(config: catalog_config, realtime_factory: ->(*) { nil }), api)
    [false, 1, "root", []].each do |environment|
      code, answer = open(daemon, prompt: "Work", model: "dev/test", environment: environment)
      assert_equal "400", code, answer.inspect
      assert_equal "environment must be an object with a root", answer.dig("error", "message")
    end
    [false, 1, "path", {}, [nil], [1], [{}]].each do |attachments|
      code, answer = open(daemon, prompt: "Work", model: "dev/test", attachments: attachments)
      assert_equal "400", code, answer.inspect
      assert_equal "attachments must be a list of file paths", answer.dig("error", "message")
    end
    assert_empty api.conversation_creates
    assert_empty api.uploads
    [nil, []].each do |attachments|
      code, answer = open(daemon, prompt: "Work", model: "dev/test", environment: nil, attachments: attachments)
      assert_equal "201", code, answer.inspect
    end
  end

  def test_nonstring_schedule_values_keep_the_boundary_refusal
    api = kernel_api
    daemon = member_ready(boot(config: catalog_config, realtime_factory: ->(*) { nil }), api)
    code, answer = open(daemon, prompt: "Work", model: "dev/test")
    assert_equal "201", code, answer.inspect
    id = answer.dig("conversation", "public_id")
    submitted = api.conversation_inputs.length

    %w[deliver_at deliver_in].each do |field|
      [false, 1, [], {}].each do |value|
        response = request(daemon, :post, "/say", token: bearer(daemon),
          body: { public_id: id, text: "Later", field => value, wait: false })
        assert_equal "400", response.code, response.body
        assert_equal "deliver_at and deliver_in are strings", JSON.parse(response.body).dig("error", "message")
      end
    end
    assert_equal submitted, api.conversation_inputs.length
  end

  private

    def assert_turn_refresh(requests)
      paths = requests.map(&:first)
      assert_equal 1, paths.count("/agent_api/v1/executors")
      assert_equal 1, paths.count("/agent_api/v1/profile/agents")
      assert_equal 1, paths.count("/agent_api/v1/tools/assembly")
      assert_operator paths.index("/agent_api/v1/executors"), :<, paths.index("/agent_api/v1/tools/assembly")
    end
end
