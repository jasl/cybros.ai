require "test_helper"
require "base64"
require "support/nexus_doubles"
require "support/daemon_harness"
require "cybros_agent/test_support/fake_realtime"

module RhoTest
  module DaemonRunHelpers
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

    def run_host(public_id) = Rho::Host::Run.new(public_id: public_id)

    def conversation_host(public_id) = Rho::Host::Conversation.new(public_id: public_id)

    def followed(daemon)
      JSON.parse(request(daemon, :get, "/followers", token: bearer(daemon)).body).fetch("followers")
    end

    # The fake's kernel catalog and the settings that name it, so the
    # declaration the daemon assembles carries `task`.
    def kernel_api(**options)
      NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE, tools: NexusDoubles::KERNEL_CATALOG, **options)
    end

    def catalog_config(settings = {})
      Rho::Config.from_hash({ "kernel_tools" => NexusDoubles::KERNEL_TOOLS.keys }.merge(settings))
    end

    # A LOCAL ROW for the mock's reference under the home's `adaptations/`:
    def mock_row(id = "mock", **fields)
      RhoTest::LocalRows.write(File.join(@root, "adaptations"), id, **{ models: ["mock-text"] }.merge(fields))
    end

    def input_materialized_event(sequence, input:, turn:, variant: "v-1", run_id: "al-1", conversation: "c-1")
      { "public_id" => "ev-#{sequence}", "sequence" => sequence, "cursor" => "c#{sequence}", "type" => "input_materialized",
        "resource" => { "type" => "conversation", "public_id" => conversation }, "occurred_at" => "2026-09-18T00:00:00Z",
        "payload" => { "input_public_id" => input, "queue_position" => 0, "turn_public_id" => turn,
                       "variant_public_id" => variant, "run_public_id" => run_id } }
    end
  end
end
