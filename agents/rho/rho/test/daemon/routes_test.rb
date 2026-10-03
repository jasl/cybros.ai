require "test_helper"

# THE ONE GUARD every bearer route runs under: the local bearer, the admission gate the passphrase does not
# touch, and the one exception map that relays a kernel refusal the caller
# can act on as itself — proven through an extension's route on each lane,
# because the map is applied once, above every handler.
class DaemonRoutesTest < Minitest::Test
  include RhoTest::DaemonHarness

  # Everything but the readiness probe carries the per-boot local bearer, which
  # authorizes this surface and no kernel request at all.
  def test_the_control_surface_refuses_without_the_local_bearer
    daemon = boot

    assert_equal "401", request(daemon, :get, "/status").code
    assert_equal "401", request(daemon, :get, "/status", token: "rho-local-v1-wrong").code
    assert_equal "401", request(daemon, :post, "/device/start").code
    assert_equal "401", request(daemon, :post, "/device/cancel").code
    assert_equal "401", request(daemon, :get, "/runners").code
    assert_equal "401", request(daemon, :post, "/handoff").code
    assert_equal "200", request(daemon, :get, "/status", token: bearer(daemon)).code
  end

  # The lock gates the BOOTSTRAP, not the control routes: those already
  # demand the bearer and always did.
  def test_the_control_routes_are_unchanged_by_the_lock
    daemon = boot(config: locked_config)

    assert_equal "401", request(daemon, :get, "/status").code
    assert_equal "200", request(daemon, :get, "/status", token: bearer(daemon)).code
    assert_equal "200", get(daemon, "/healthz").code, "the readiness probe stays free"
  end

  # WHOSE MISTAKE WAS IT. Every SDK failure used to leave here as a 502, so a
  # caller who mistyped something was told the gateway had failed — while the
  # typed code rode along inside a status contradicting it.
  def test_a_refusal_the_caller_can_act_on_keeps_its_own_status
    daemon = one_shot_ready(boot)
    raised = nil
    # The kernel's refusal, as the SDK raises it from the wire.
    daemon.wire.api_transport = Object.new.tap do |transport|
      transport.define_singleton_method(:call) { |*, **| raise raised }
    end
    post = -> { route(daemon, "POST", "/one_shots").call(json_request(one_shot_body, token: bearer(daemon))) }

    raised = CybrosAgent::Api::InvalidRequest.new("bad", code: "unsupported_generation_parameter")
    assert_equal [422, "unsupported_generation_parameter"], post.call.then { |s, b| [s, b.dig(:error, :code)] }

    raised = CybrosAgent::Api::Conflict.new("mismatch", code: "idempotency_envelope_mismatch")
    assert_equal [409, "idempotency_envelope_mismatch"], post.call.then { |s, b| [s, b.dig(:error, :code)] }

    raised = CybrosAgent::Api::ContentTooLarge.new("large", code: "request_too_large")
    assert_equal [413, "request_too_large"], post.call.then { |s, b| [s, b.dig(:error, :code)] }

    raised = CybrosAgent::Api::RateLimited.new(retry_after: 7)
    status, body = post.call
    assert_equal 429, status
    assert_equal "rate_limited", body.dig(:error, :code)
    assert_equal 7, body.dig(:error, :retry_after)

    # ONE MAP FOR EVERY LANE: a 404 the kernel attributes
    # to the request crosses as itself here too, where this lane said 502.
    raised = CybrosAgent::Api::NotFound.new("gone", code: "workspace_not_found")
    assert_equal [404, "workspace_not_found"], post.call.then { |s, b| [s, b.dig(:error, :code)] }

    # AND THE REST STAY 502, on purpose: a credential or workspace this daemon
    # holds being wrong is nothing its caller can fix from the outside.
    raised = CybrosAgent::Api::Unauthorized.new("nope", code: "credential_not_accepted")
    status, = post.call
    assert_equal 502, status
  end

  # THE SAME MAP ON THE LOOP LANE: a size or rate refusal
  # the kernel attributes to the request is relayed as itself, where the
  # loop verbs used to fold both into 502.
  def test_a_loop_verb_relays_a_size_or_rate_refusal_as_itself
    too_large = CybrosAgent::Response.new(
      status: 413, headers: {},
      body: { "error" => { "code" => "request_too_large", "message" => "too big" } }
    )
    daemon = member_ready(boot, NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::HALTED_TRACE, adjudication: too_large))
    refused = request(daemon, :post, "/loops/retry",
      token: bearer(daemon), body: { public_id: "al-9", task_key: "round1" })
    assert_equal "413", refused.code
    assert_equal "request_too_large", JSON.parse(refused.body).dig("error", "code")

    throttled = CybrosAgent::Response.new(
      status: 429, headers: { "retry-after" => "7" },
      body: { "error" => { "code" => "rate_limited", "message" => "slow down" } }
    )
    daemon.wire.api_transport = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::HALTED_TRACE, adjudication: throttled)
    refused = request(daemon, :post, "/loops/retry",
      token: bearer(daemon), body: { public_id: "al-9", task_key: "round1" })
    assert_equal "429", refused.code
    assert_equal 7, JSON.parse(refused.body).dig("error", "retry_after")
  end
end
