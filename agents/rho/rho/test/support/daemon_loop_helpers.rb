require "test_helper"
require "base64"
require "support/nexus_doubles"
require "support/daemon_harness"
require "cybros_agent/test_support/fake_realtime"

module RhoTest
  module DaemonLoopHelpers
    include RhoTest::DaemonHarness

    def open(daemon, body)
      response = request(daemon, :post, "/conversations", token: bearer(daemon), body: body)
      [response.code, JSON.parse(response.body)]
    end

    def store = host_store

    PNG = Base64.decode64(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )

    def picture_file(name)
      File.join(@root, name).tap { |path| File.binwrite(path, PNG) }
    end

    def loop_host(public_id) = Rho::Host::AgentLoop.new(public_id: public_id)

    def conversation_host(public_id) = Rho::Host::Conversation.new(public_id: public_id)

    def followed(daemon)
      JSON.parse(request(daemon, :get, "/loops", token: bearer(daemon)).body).fetch("loops")
    end

    # The fake's two-tool kernel catalog and the settings that name it, so the
    # declaration the daemon assembles carries `compose` beside `task`.
    def kernel_api(**options)
      NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE, tools: NexusDoubles::KERNEL_CATALOG, **options)
    end

    def tiered(settings = {})
      Rho::Config.from_hash({ "kernel_tools" => NexusDoubles::KERNEL_TOOLS.keys }.merge(settings))
    end

    # A LOCAL ROW for the mock's reference under the home's `adaptations/`:
    # `compose: off` is the row's word, read by the
    # switch's `auto` rung — the per-model table it replaced.
    def mock_row(id = "mock-off", **fields)
      RhoTest::LocalRows.write(File.join(@root, "adaptations"), id, **{ models: ["mock-text"], compose: "off" }.merge(fields))
    end

    # Every declared flat name but compose, in declaration order: this
    # machine's tools, then the kernel's.
    def names_without_compose
      registry = Rho::Extensions.load(host: RhoTest.host).registry
      Rho::LoopRequest.tool_entries(Rho::LoopRequest.announcement(registry: registry))
        .map { |entry| entry.dig("function", "name") } + ["task"]
    end

    def input_materialized_event(sequence, input:, turn:, conversation: "c-1")
      { "public_id" => "ev-#{sequence}", "sequence" => sequence, "cursor" => "c#{sequence}", "type" => "input_materialized",
        "resource" => { "type" => "conversation", "public_id" => conversation }, "occurred_at" => "2026-09-18T00:00:00Z",
        "payload" => { "input_public_id" => input, "queue_position" => 0, "turn_public_id" => turn } }
    end
  end
end
