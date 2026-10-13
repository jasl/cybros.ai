require "support/daemon_run_helpers"

class DaemonForeignAnswererTest < Minitest::Test
  include RhoTest::DaemonRunHelpers

  def test_promptless_foreign_conversation_does_not_inherit_local_runner_defaults
    api = foreign_api
    daemon = member_ready(boot(config: catalog_config, realtime_factory: ->(*) { nil }), api, identity: RUNNER_IDENTITY)

    [nil, "0199-saved-local"].each do |saved|
      File.write(daemon.home.settings_path, JSON.generate({ "runner" => saved }.compact))
      code, answer = open(daemon, { "agent" => "@lark" })
      assert_equal "201", code, answer.inspect
      assert_equal "peer-1", api.conversation_creates.last.dig("conversation", "answering_user_public_id")
      assert_nil api.conversation_creates.last.dig("conversation", "default_runner_executor_public_id"),
        "a foreign answerer does not inherit this instance's own or saved Runner"
      assert_nil answer.fetch("default_runner")
      assert_equal "peer-1", store.find(answer.dig("conversation", "public_id")).answerer
      assert_empty api.conversation_inputs
    end
  end

  def test_first_say_keeps_foreign_answerer_and_selected_runner
    [{}, { "default_runner_executor_public_id" => nil },
      { "default_runner_executor_public_id" => "0199-peer-private" }].each_with_index do |selection, index|
      runner = selection["default_runner_executor_public_id"]
      api = foreign_api
      daemon = member_ready(boot(root: File.join(@root, index.to_s), config: catalog_config,
        realtime_factory: ->(*) { nil }), api, identity: RUNNER_IDENTITY)
      File.write(daemon.home.settings_path, JSON.generate("runner" => "0199-saved-local"))

      code, answer = open(daemon, { "agent" => "@lark" }.merge(selection))
      assert_equal "201", code, answer.inspect
      assert_equal "peer-1", api.conversation_creates.last.dig("conversation", "answering_user_public_id")
      assert_equal [runner], [api.conversation_creates.last.dig("conversation", "default_runner_executor_public_id")]
      id = answer.dig("conversation", "public_id")
      assert_equal ["peer-1", runner], [store.find(id).answerer, store.find(id).runner]
      assert_empty api.conversation_inputs

      response = request(daemon, :post, "/say", token: bearer(daemon),
        body: { public_id: id, text: "first words", model: "dev/mock-text", wait: false })
      assert_equal "200", response.code, response.body
      assert_equal [runner], [JSON.parse(response.body).dig("default_runner", "executor_public_id")]
      input = api.conversation_inputs.last.fetch("input")
      assert_empty input.keys & %w[answering_user_public_id execution_declaration tool_names approval_mode inline],
        "the first say retains the conversation's answerer and lets Nexus use its declaration"
      assert_equal ["peer-1", runner], [store.find(id).answerer, store.find(id).runner]
      assert_empty api.tool_assemblies
      refute_includes api.requests.map(&:first), "/agent_api/v1/executors/0199-peer-private"
    end
  end

  def test_promptless_own_and_registered_answerers_keep_local_runner_defaults
    definition = Rho::Agents::Definition.new(name: "author", description: "Authors work", tools: ["read"],
      model: nil, body: "Complete the task.", path: "<extension>", ignored_keys: [])
    extension = Module.new do
      const_set(:NAME, "rho.author")
      define_singleton_method(:register) { |api| api.register_agent(definition) }
    end
    api = kernel_api(user_public_id: IDENTITY.user_public_id)
    daemon = member_ready(boot(config: catalog_config,
      extensions: Rho::Extensions::DEFAULT_EXTENSIONS + [extension], realtime_factory: ->(*) { nil }), api, identity: RUNNER_IDENTITY)
    daemon.context.declare_profile
    api.stock_principals(api.named_agents_listing.body.fetch("agents").map do |row|
      row.slice("public_id", "handle", "kind", "display_name", "agent_identifier", "steward_public_id")
    end)

    [nil, "0199-saved-local"].each do |saved|
      File.write(daemon.home.settings_path, JSON.generate({ "runner" => saved }.compact))
      [{}, { "agent" => "@author" }].each do |body|
        code, answer = open(daemon, body)
        assert_equal "201", code, answer.inspect
        assert_equal saved || RUNNER_IDENTITY.runner_executor_public_id,
          api.conversation_creates.last.dig("conversation", "default_runner_executor_public_id")
        assert_empty api.conversation_inputs
      end
    end
  end

  private

    def foreign_api
      api = kernel_api
      api.stock_principals([
        { "public_id" => "steward-1", "handle" => "steward", "kind" => "human", "display_name" => "Steward",
          "agent_identifier" => nil, "steward_public_id" => nil },
        { "public_id" => IDENTITY.user_public_id, "handle" => "rho", "kind" => "agent", "display_name" => "rho",
          "agent_identifier" => "rho.1", "steward_public_id" => "steward-1" },
        { "public_id" => "peer-1", "handle" => "lark", "kind" => "agent", "display_name" => "Lark",
          "agent_identifier" => "rho.2", "steward_public_id" => "steward-1" },
      ])
      api
    end
end
