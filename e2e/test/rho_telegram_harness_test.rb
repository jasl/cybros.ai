require "test_helper"
require "minitest/mock"
require_relative "support/rho_telegram_case"

class RhoTelegramHarnessTest < Minitest::Test
  class RecordingDaemon
    attr_reader :targets, :allowed_chats

    def initialize
      @targets = []
      @allowed_chats = []
    end

    def control(method, path, body: nil)
      case [method, path.split("?").first]
      when [:put, "/agents"]
        { "agent" => { "public_id" => body.fetch(:name) } }
      when [:put, "/agents/settings"]
        {}
      when [:post, "/telegram/configuration"]
        @targets << body.fetch("target")
        { "saved" => true }
      when [:get, "/telegram"]
        { "access" => {} }
      when [:post, "/telegram/access"]
        @allowed_chats << body.fetch(:id)
        { "access" => { "allowed_chats" => [body.fetch(:id).to_s] } }
      else
        raise "Unexpected fixture request: #{method} #{path}"
      end
    end

    def await(*) = yield
  end

  class MemoryDocument
    def initialize = @value = {}
    def read = @value

    def change
      yield @value
      @value
    end
  end

  def test_scoped_group_fixtures_keep_the_private_recipient_and_both_topic_bindings
    fixture, daemon = fixture_case
    defaults = fixture.send(:telegram_bot_targets)
    assert_equal %w[101:0 102:0 -10:7 -10:8], defaults.keys
    fixture.stub(:telegram_bot_targets, defaults.except("101:0")) do
      fixture.send(:declare_telegram_bots, "workspace")
    end
    assert_equal [
      { "chat_id" => 102, "topic_id" => nil },
      { "chat_id" => -10, "topic_id" => 7 },
      { "chat_id" => -10, "topic_id" => 8 },
    ], daemon.targets
    assert_equal [-10, -10], daemon.allowed_chats

    boot(fixture)
    bindings = fixture.instance_variable_get(:@bot_runtimes).values
    { [102, nil] => 1, [-10, 7] => 1, [-10, 8] => 1, [-20, 7] => 0, [-10, nil] => 0 }.each do |(chat, topic), count|
      incoming = fixture.send(:update, [chat, topic], "A room message", chat: chat, topic: topic)
      update = Rho::IngressTelegram::Update.new(incoming)
      assert_equal count, bindings.count { |runtime| runtime.settings.matches?(update) }
    end
  end

  def test_boot_selects_a_declared_destination_and_preserves_selection_on_restart
    fixture, = fixture_case
    targets = fixture.send(:telegram_bot_targets).except("101:0")
    fixture.stub(:telegram_bot_targets, targets) { fixture.send(:declare_telegram_bots, "workspace") }
    boot(fixture)
    assert_equal "102:0", fixture.instance_variable_get(:@selected_route)
    fixture.send(:select_bot, "-10:8")
    boot(fixture)
    assert_equal "-10:8", fixture.instance_variable_get(:@selected_route)
    assert_same fixture.instance_variable_get(:@states).fetch("-10:8"), fixture.instance_variable_get(:@state)
  end

  private

    def fixture_case
      fixture = E2E::RhoTelegramCase.new("fixture")
      daemon = RecordingDaemon.new
      { daemon: daemon, connection_id: SecureRandom.uuid, logs: [], telegram: E2E::TelegramClient.new,
        bot: E2E::TelegramClient::BOT, core: Object.new, telegram_host: Object.new }.each do |key, value|
        fixture.instance_variable_set(:"@#{key}", value)
      end
      [fixture, daemon]
    end

    def boot(fixture)
      Rho::StoreDocument.stub(:new, ->(**) { MemoryDocument.new }) do
        fixture.send(:boot_runtime, allowed: [101])
      end
    end
end
