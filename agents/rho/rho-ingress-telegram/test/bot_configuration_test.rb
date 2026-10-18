require "test_helper"

class TelegramBotConfigurationTest < Minitest::Test
  BOT = "019a1111-2222-7333-8444-555555555555".freeze

  CONNECTION = "019a1111-2222-7333-8444-555555555551".freeze
  OTHER_BOT = "019a1111-2222-7333-8444-555555555552".freeze

  def test_bots_share_a_connection_but_keep_independent_targets_and_admission_settings
    bindings = Rho::IngressTelegram::Settings.bindings(document)
    assert bindings.fetch(OTHER_BOT).enabled?
    refute bindings.fetch(BOT).enabled?
    assert bindings.fetch(BOT).configured?
    assert_equal "2", bindings.fetch(BOT).owner_id
    assert_equal 0, bindings.fetch(BOT).input_debounce_seconds
    assert_equal [CONNECTION], bindings.values.map(&:connection_public_id).uniq
    assert_equal ["1", "2"], bindings.values.map { |row| row.target.fetch("chat_id") }.sort
    refute_includes bindings.values.map(&:to_h).to_json, "secret"
  end

  def test_schema_redacts_every_connection_token_and_does_not_accept_credentials_on_bots
    descriptor = Rho::Extensions::Catalog.new.fetch(Rho::IngressTelegram::NAME)
    edited = descriptor.schema.edit(descriptor.schema.normalize(document).overrides, operations: [
      { "op" => "set", "path" => ["connections", OTHER_BOT, "token"], "value" => "another-secret" },
    ])
    view = descriptor.schema.view(edited).to_h
    refute_includes JSON.generate(view), "shared-secret"
    refute_includes JSON.generate(view), "another-secret"
    assert_equal [["connections", CONNECTION, "token"], ["connections", OTHER_BOT, "token"]], view.fetch(:secrets).map { |secret| secret.fetch(:path) }
    assert_raises(Rho::ConfigurationError) { Rho::IngressTelegram::Settings.bindings("bots" => { "rho" => {} }) }
    assert_raises(Rho::ConfigurationError) { Rho::IngressTelegram::Settings.new("token" => "old-secret") }
  end

  def test_management_routes_select_only_an_editable_owned_bot
    context = Object.new
    context.define_singleton_method(:list_named_agents) { { bots: [{ public_id: BOT, home_workspace_public_id: nil, audience: "owner" }] } }
    coordinator = Object.new
    coordinator.define_singleton_method(:status) { |agent_public_id:, audience:| { "agent_public_id" => agent_public_id } }
    request = Protocol::HTTP::Request["GET", "/telegram?agent_public_id=#{BOT}"]
    assert_equal [200, { "agent_public_id" => BOT }], Rho::IngressTelegram.status(request, context, coordinator)
    assert_equal 400, Rho::IngressTelegram.agent_selector(nil, nil).status

    context.singleton_class.remove_method(:list_named_agents)
    context.define_singleton_method(:list_named_agents) { { bots: [{ public_id: BOT }] } }
    refusal = Rho::IngressTelegram.status(request, context, coordinator)
    assert_equal 404, refusal.status
    assert_equal "bot_unavailable", refusal.code
    assert_equal 400, Rho::IngressTelegram.agent_selector(context, "named-bot").status
  end

  def test_access_management_uses_the_selected_external_bot_even_while_disabled
    row = { public_id: BOT, home_workspace_public_id: nil, audience: "external" }
    context = Object.new
    context.define_singleton_method(:list_named_agents) { { bots: [row] } }
    calls = []
    coordinator = Object.new
    coordinator.define_singleton_method(:change_access) { |**fields| calls << fields }
    coordinator.define_singleton_method(:status) { |**fields| fields }
    request = -> {
      Protocol::HTTP::Request["POST", "/telegram/access", { "content-type" => "application/json" },
        [JSON.generate(agent_public_id: BOT, list: "allowed_users", action: "add", id: "7")]]
    }
    answer = Rho::IngressTelegram.change_access(request.call, coordinator, context)
    assert_equal [200, { agent_public_id: BOT, audience: "external" }], answer
    assert_equal [{ agent_public_id: BOT, list: "allowed_users", action: "add", id: "7" }], calls
    row[:audience] = "owner"
    refusal = Rho::IngressTelegram.change_access(request.call, coordinator, context)
    assert_equal 422, refusal.status
    assert_equal "bot_owner_only", refusal.code
    assert_equal 1, calls.length
  end

  def test_preparation_changes_only_the_selected_bot_and_does_not_read_a_connection_token
    config = Rho::Config.from_hash({ "mode" => "agent", "plugins" => { Rho::IngressTelegram::NAME => {
      "enabled" => true, "configuration" => document,
    } } })
    configuration = Rho::IngressTelegram::Configuration.new(config: config, clients: ->(*) { raise "unexpected Telegram IO" })
    prepared = configuration.prepare({ "owner_id" => "3" }, agent_public_id: BOT)
    assert_equal BOT, prepared.agent_public_id
    assert_equal [{ "op" => "set", "path" => ["bots", BOT, "owner_id"], "value" => "3" }], prepared.operations
    assert_nil prepared.token
    assert_equal "1", config.plugin_configuration(Rho::IngressTelegram::NAME).dig("bots", OTHER_BOT, "owner_id")
  end

  private

    def document
      { "connections" => { CONNECTION => { "token" => "shared-secret" } }, "bots" => {
        OTHER_BOT => { "enabled" => true, "connection_public_id" => CONNECTION, "target" => { "chat_id" => "1" }, "owner_id" => "1" },
        BOT => { "enabled" => false, "connection_public_id" => CONNECTION, "target" => { "chat_id" => "2" }, "owner_id" => "2", "input_debounce_seconds" => 0 },
      } }
    end
end
