require_relative "../test_helper"
require_relative "../support/ops_harness"

class OpsActivationTest < Minitest::Test
  include RhoTest::OpsHarness

  class ActivationApi < NexusDoubles::FakeAgentApi
    attr_reader :activations
    attr_accessor :activation_response

    def initialize
      super
      @activations = []
      @activation_response = respond(200, { "variant" => {
        "public_id" => "v-1", "source" => "agent_loop", "status" => "completed", "active" => true,
        "agent_loop_public_id" => "al-old", "content_preview" => "the selected reply",
      } })
    end

    def call(path, method: :get, **options)
      return super unless method == :post && path.end_with?("/activation")

      @activations << [path, options.fetch(:credential)]
      activation_response
    end
  end

  def test_activation_uses_the_member_sdk_door_without_a_local_follow_or_conceal_write
    api = ActivationApi.new
    daemon = member_ready(boot, api)
    response = request(daemon, :post, "/conversations/activate", token: bearer(daemon),
      body: { public_id: "c-1", turn: "t-1", variant: "v-1" })

    assert_equal "200", response.code, response.body
    variant = JSON.parse(response.body).fetch("variant")
    assert_equal "v-1", variant.fetch("public_id")
    assert_equal true, variant.fetch("active")
    assert_equal "al-old", variant.fetch("agent_loop_public_id")
    assert_equal [["/agent_api/v1/workspaces/ws-1/conversations/c-1/turns/t-1/variants/v-1/activation",
      NexusDoubles::MEMBER_TOKEN]], api.activations
    assert_empty api.variant_updates
    assert_empty store.rows
  end

  def test_activation_requires_all_three_identifiers_before_calling_the_kernel
    api = ActivationApi.new
    daemon = member_ready(boot, api)
    body = { public_id: "c-1", turn: "t-1", variant: "v-1" }

    body.each_key do |key|
      response = request(daemon, :post, "/conversations/activate", token: bearer(daemon), body: body.except(key))
      assert_equal "400", response.code, response.body
      assert_equal "#{key} is required", JSON.parse(response.body).dig("error", "message")
    end
    assert_empty api.activations
  end

  def test_activation_preserves_the_kernel_conflict
    api = ActivationApi.new
    api.activation_response = CybrosAgent::Response.new(status: 409, headers: {},
      body: { "error" => { "code" => "variant_not_active", "message" => "candidate is still running" } })
    daemon = member_ready(boot, api)
    response = request(daemon, :post, "/conversations/activate", token: bearer(daemon),
      body: { public_id: "c-1", turn: "t-1", variant: "v-1" })

    assert_equal "409", response.code, response.body
    assert_equal "variant_not_active", JSON.parse(response.body).dig("error", "code")
    assert_equal 1, api.activations.length
    assert_empty api.variant_updates
  end
end
