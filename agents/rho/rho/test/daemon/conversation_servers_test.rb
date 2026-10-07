require "test_helper"
require "support/nexus_doubles"
require "support/daemon_harness"

# THE EDITOR'S SERVERS IN A TURN'S SCOPE: every anchor's `mcp__` names but the turn's own
# anchor's are subtracted from the turn's names UNCONDITIONALLY — with
# or without a runner elsewhere in the union — while the turn's own
# anchor's names ride its `own_names`; a turn with nothing foreign to
# subtract keeps the whole declaration (no `tool_names`) as before, and
# the union is declared once per set change, never per turn. Driven the
# way the ACP surface drives it: the conversation opened with its root
# set, the servers bound through the door, the say on each conversation.
class ConversationServersTest < Minitest::Test
  include RhoTest::DaemonHarness

  def open(daemon, body)
    response = request(daemon, :post, "/conversations", token: bearer(daemon), body: body)
    [response.code, JSON.parse(response.body)]
  end

  def say(daemon, public_id, text)
    response = request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: public_id, text: text })
    assert_equal "200", response.code, response.body
    JSON.parse(response.body)
  end

  def bind(daemon, body)
    response = request(daemon, :post, "/conversations/environment", token: bearer(daemon), body: body)
    [response.code, JSON.parse(response.body)]
  end

  def project(name) = File.join(@root, name).tap { |path| FileUtils.mkdir_p(path) }

  def kernel_api(**options)
    NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE, tools: NexusDoubles::KERNEL_CATALOG, **options)
  end

  def catalog_config(settings = {})
    Rho::Config.from_hash({ "kernel_tools" => NexusDoubles::KERNEL_TOOLS.keys }.merge(settings))
  end

  def servers_extension
    @closes = File.join(@root, "closes.txt")
    RhoTest::ConversationServers.extension(@root, closes: @closes)
  end

  def last_input(api) = api.conversation_inputs.last.fetch("input")

  def declared_names(api)
    api.configuration_declarations.last.dig("configuration", "tool_definitions").map { |entry| entry.dig("function", "name") }
  end

  # Two conversations on this machine's own runner, one editor binding
  # its servers on the first: the first's turns see the full declaration
  # with no `tool_names` because nothing is foreign; the
  # second's turns are narrowed to the declaration minus the first's
  # servers, its own tools and the kernel's intact; then a second editor
  # on the second conversation, and each sees its own alone. The union
  # carries every anchor's names and is declared once per set change.
  def assembled_names(daemon)
    daemon.context.member_plane(require_workspace: false) do |client, *|
      client.tools.assemble(default_runner_executor_public_id: RUNNER_IDENTITY.runner_executor_public_id)
        .tool_definitions.map { |entry| entry.dig("function", "name") }
    end
  end

  def test_a_turn_is_offered_its_own_anchors_servers_and_never_another_anchors
    api = kernel_api
    daemon = member_ready(boot(config: catalog_config("plugins" => { "rho.mcp" => { "enabled" => false }, "rho.servers" => servers_extension })), api, identity: RUNNER_IDENTITY)
    src_a = project("a")
    src_b = project("b")

    code, answer = open(daemon, { "prompt" => "start", "model" => "dev/mock-text", "environment" => { "root" => src_a } })
    assert_equal "201", code, answer.inspect
    a = answer.dig("conversation", "public_id")
    code, answer = open(daemon, { "prompt" => "start", "model" => "dev/mock-text", "environment" => { "root" => src_b } })
    assert_equal "201", code, answer.inspect
    b = answer.dig("conversation", "public_id")
    declared_before = api.configuration_declarations.length

    code, answer = bind(daemon, { public_id: a, mcp: [RhoTest::ConversationServers.stdio("fx")] })
    assert_equal "200", code, answer.inspect
    assert_equal declared_before + 1, api.configuration_declarations.length, "the union declared once for the set"
    assert_includes declared_names(api), "mcp__fx__lookup"
    assert_includes declared_names(api), "mcp__fx__paths"

    say(daemon, a, "use the editor")
    refute last_input(api).key?("tool_names"), "the anchor's own turn: nothing foreign, the whole declaration as before"
    assert_equal declared_before + 1, api.configuration_declarations.length, "a turn never re-declares"

    say(daemon, b, "you cannot")
    names = last_input(api).fetch("tool_names")
    refute_includes names, "mcp__fx__lookup", "another conversation's editor: subtracted, with no runner elsewhere in the union"
    refute_includes names, "mcp__fx__paths"
    assert_equal assembled_names(daemon) - %w[mcp__fx__lookup mcp__fx__paths], names, "the whole declaration minus the foreign names, in order"
    assert_includes names, "bash", "this machine's own tools stand"
    assert_includes names, "delegate_task", "the kernel's stand"
    assert_equal declared_before + 1, api.configuration_declarations.length

    code, answer = bind(daemon, { public_id: b, mcp: [RhoTest::ConversationServers.stdio("gx")] })
    assert_equal "200", code, answer.inspect
    assert_equal declared_before + 2, api.configuration_declarations.length
    assert_includes declared_names(api), "mcp__gx__lookup"

    say(daemon, a, "again")
    names = last_input(api).fetch("tool_names")
    assert_equal assembled_names(daemon) - %w[mcp__gx__lookup mcp__gx__paths], names, "a's turn: b's servers gone, a's own kept"
    assert_includes names, "mcp__fx__lookup"

    say(daemon, b, "again")
    names = last_input(api).fetch("tool_names")
    assert_equal assembled_names(daemon) - %w[mcp__fx__lookup mcp__fx__paths], names, "b's turn: a's servers gone, b's own kept"
    assert_includes names, "mcp__gx__lookup"

    code, = bind(daemon, { public_id: a, mcp: [] })
    assert_equal "200", code
    assert_equal declared_before + 3, api.configuration_declarations.length, "the close moved the union once"
    refute_includes declared_names(api), "mcp__fx__lookup"
    say(daemon, b, "alone now")
    refute last_input(api).key?("tool_names"), "nothing foreign left: the whole declaration again"
    assert_equal ["#{a}"], File.read(@closes).split("\n")

    log = File.read(daemon.home.log_path, encoding: Encoding::UTF_8)
    refute_includes log, "hunter2", "the env value never reaches the log"
  end

  # THE ANCHOR IS THE RECORD'S: a conversation with no root set has no
  # anchor and no servers; the open itself (no anchor yet) offers none —
  # and a bind through the door on a conversation whose record a
  # later `say` reads finds them on that say.
  def test_the_servers_follow_the_record_read_at_say_and_the_open_offers_none
    api = kernel_api
    daemon = member_ready(boot(config: catalog_config("plugins" => { "rho.mcp" => { "enabled" => false }, "rho.servers" => servers_extension })), api, identity: RUNNER_IDENTITY)

    code, answer = open(daemon, { "prompt" => "start", "model" => "dev/mock-text",
                                  "environment" => { "root" => project("a") } })
    assert_equal "201", code, answer.inspect
    a = answer.dig("conversation", "public_id")
    refute last_input(api).key?("tool_names"), "no servers are declared yet"
    refute daemon.context.environments.servers.names.include?("mcp__fx__lookup")

    assert_equal "200", bind(daemon, { public_id: a, mcp: [RhoTest::ConversationServers.stdio("fx")] }).first
    say(daemon, a, "now")
    refute last_input(api).key?("tool_names"), "the only servers belong to this anchor"
    assert_includes declared_names(api), "mcp__fx__lookup"
    assert_includes declared_names(api), "mcp__fx__paths"
  end

  def test_side_turns_keep_the_inherited_anchors_servers_without_expanding_the_read_posture
    api = kernel_api(user_public_id: IDENTITY.user_public_id)
    daemon = member_ready(boot(config: catalog_config("plugins" => { "rho.mcp" => { "enabled" => false }, "rho.servers" => servers_extension }),
      realtime_factory: ->(*) { nil }), api, identity: RUNNER_IDENTITY)
    code, answer = open(daemon, { "prompt" => "start", "model" => "dev/mock-text", "environment" => { "root" => project("other") } })
    assert_equal "201", code, answer.inspect
    other = answer.dig("conversation", "public_id")
    assert_equal "200", bind(daemon, { public_id: other, mcp: [RhoTest::ConversationServers.stdio("gx")] }).first

    %w[write read].each do |tools|
      code, answer = open(daemon, { "prompt" => "start", "model" => "dev/mock-text", "environment" => { "root" => project(tools) } })
      assert_equal "201", code, answer.inspect
      parent = answer.dig("conversation", "public_id")
      assert_equal "200", bind(daemon, { public_id: parent, mcp: [RhoTest::ConversationServers.stdio("fx")] }).first
      say(daemon, parent, "use this editor")
      ordinary = last_input(api).fetch("tool_names")
      assert_includes ordinary, "mcp__fx__lookup"
      refute_includes ordinary, "mcp__gx__lookup"
      assert_includes ordinary, "code"

      response = request(daemon, :post, "/side", token: bearer(daemon),
        body: { parent_public_id: parent, tools: tools, text: "use the inherited editor" })
      assert_equal "201", response.code, response.body
      side_id = JSON.parse(response.body).dig("side", "public_id")
      assert_equal parent, daemon.context.environments.binding_for(side_id, runner: RUNNER_IDENTITY.runner_executor_public_id).anchor
      initial = last_input(api)
      say(daemon, side_id, "continue with the same tools")
      later = last_input(api)
      [initial, later].each do |input|
        names = input.fetch("tool_names")
        if tools == "read"
          assert_includes names, "read"
          assert_empty names.grep(/\Amcp__/)
          refute_includes names, "code"
        else
          assert_equal ordinary, names
        end
        assert_equal [{ "role" => "user", "position" => "tail", "text" => Rho::Daemon::HostFollowers::SIDE_LEADS.fetch(tools) }],
          input.fetch("inline"), "reading the environment must not add a side developer lead"
      end
    end
  end
end
