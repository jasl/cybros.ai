require "support/daemon_run_helpers"

class DaemonPromptlessModelSelectionTest < Minitest::Test
  include RhoTest::DaemonRunHelpers

  def test_a_promptless_explicit_provider_route_stays_pinned_on_the_first_input
    api = kernel_api(user_public_id: IDENTITY.user_public_id)
    daemon = member_ready(boot(realtime_factory: ->(*) { nil },
      config: catalog_config("default_model" => "dev/default", "fallback_models" => ["other/requested"])), api)

    code, opened = open(daemon, { "model" => "dev/requested" })
    assert_equal "201", code, opened.inspect
    assert_empty api.conversation_inputs

    response = request(daemon, :post, "/say", token: bearer(daemon), body: {
      public_id: opened.fetch("conversation").fetch("public_id"), text: "First task", wait: false,
    })
    assert_equal "200", response.code, response.body
    input = api.conversation_inputs.last.fetch("input")
    assert_equal({ "model" => "dev/requested" }, input.fetch("model"))
    assert_equal({ "source" => "explicit", "model" => "dev/requested", "constraint" => "route", "alternatives" => [] },
      input.fetch("model_selection"))
    assert_equal ["other/requested"], input.fetch("fallback_models")
  end
end
