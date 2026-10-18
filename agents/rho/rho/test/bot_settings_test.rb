require "test_helper"
require "rho/bot_settings"
require_relative "support/environment_fixtures"

class BotSettingsTest < Minitest::Test
  def setup
    @store = RhoTest::EnvironmentFixtures::FakeStore.new
  end

  def test_missing_home_is_unset_without_creating_settings
    assert_nil settings("bot-a").read.home_workspace_public_id
    assert_equal "owner", settings("bot-a").read.audience
    assert settings("bot-a").read.subagent
    assert_empty @store.rows
  end

  def test_audience_and_home_preserve_each_other_when_only_one_is_changed
    settings("bot-a").replace(home_workspace_public_id: "ws-a", preset_public_id: "preset-a", welcome_message: "Hello")
    settings("bot-a").replace(audience: "external")
    assert_equal({ "home_workspace_public_id" => "ws-a", "audience" => "external", "preset_public_id" => "preset-a", "welcome_message" => "Hello", "subagent" => true }, settings("bot-a").read.to_h)
    settings("bot-a").replace(home_workspace_public_id: "ws-next")
    assert_equal "external", settings("bot-a").read.audience
    assert_equal ["preset-a", "Hello"], settings("bot-a").read.to_h.values_at("preset_public_id", "welcome_message")
    assert_equal "owner", settings("bot-b").read.audience
  end

  def test_new_handles_read_committed_home_without_changing_another_bot
    settings("bot-a").replace(home_workspace_public_id: "ws-a")
    settings("bot-b").replace(home_workspace_public_id: "ws-b")
    assert_equal "ws-a", settings("bot-a").read.home_workspace_public_id
    settings("bot-a").replace(home_workspace_public_id: "ws-next")
    assert_equal "ws-next", settings("bot-a").read.home_workspace_public_id
    settings("bot-a").replace(home_workspace_public_id: nil)

    assert_equal({ "home_workspace_public_id" => nil, "audience" => "owner", "preset_public_id" => nil, "welcome_message" => nil, "subagent" => true }, settings("bot-a").read.to_h)
    assert_equal "ws-b", settings("bot-b").read.home_workspace_public_id
    assert_equal %w[bot-a bot-b], @store.rows.map(&:key)
    assert_equal ["rho.bots"], @store.rows.map(&:namespace).uniq
    assert_equal [%w[home_workspace_public_id audience preset_public_id welcome_message subagent]], @store.rows.map { |row| row.value.keys }.uniq
  end

  def test_subagent_is_durable_and_other_fields_and_bots_do_not_reset_it
    settings("bot-a").replace(subagent: false)
    settings("bot-a").replace(welcome_message: "Hello")
    assert_equal false, settings("bot-a").read.subagent
    assert_equal true, settings("bot-b").read.subagent
    assert_equal "Hello", settings("bot-a").replace(subagent: true).welcome_message
    assert_equal true, settings("bot-a").read.subagent
  end

  def test_unavailable_store_never_becomes_an_unset_home
    @store.fail_reads(CybrosAgent::TransportError.new("offline"))

    assert_raises(CybrosAgent::TransportError) { settings("bot-a").read }
    assert_empty @store.rows
  end

  private

    def settings(agent_public_id)
      Rho::BotSettings.new(store: -> { @store }, agent_public_id: agent_public_id)
    end
end
