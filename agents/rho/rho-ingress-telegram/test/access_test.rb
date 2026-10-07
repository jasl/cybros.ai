require "test_helper"
require "rho/ingress-telegram/access"
require "tmpdir"
require "fileutils"

class TelegramAccessTest < Minitest::Test
  class CountingState < Rho::IngressTelegram::State
    attr_reader :changes

    def initialize(home)
      super(store: TelegramStateSupport.document(home))
      @changes = 0
    end

    def change(&block)
      @changes += 1
      super(&block)
    end
  end

  def setup
    @directory = Dir.mktmpdir("rho-telegram-access")
    @home = Rho::Home.resolve(base_url: "https://nexus.example", root: @directory).prepare
    @settings = Rho::IngressTelegram::Settings.new({ "owner_id" => 7 }, env: {})
    @state = CountingState.new(@home)
    @access = Rho::IngressTelegram::Access.new(settings: @settings, state: @state)
    @update_id = 0
  end

  def teardown = FileUtils.remove_entry(@directory)

  def test_only_the_configured_owner_is_initially_allowed
    assert @access.owner?(7)
    assert @access.allowed?(7)
    refute @access.allowed?(8)
    refute @access.allowed_chat?(-10)
    refute_path_exists File.join(@directory, "telegram", "state.json")
  end

  def test_nonowners_and_group_commands_cannot_read_or_change_access
    ["users list", "users add 8", "chats add -10"].each do |argument|
      assert_equal "Only the bot owner can manage access.", command("access", argument, user_id: 8)
      assert_equal "Manage access in a private chat with this bot.", command("access", argument, group: true)
    end
    assert_equal "Only the bot owner can manage access.", command("ignore", "add 8", user_id: 8)
    assert_equal "Manage access in a private chat with this bot.", command("ignore", "add 8", group: true)
    assert_empty @state.read.fetch("access").fetch("allowed_users")
    assert_empty @state.read.fetch("access").fetch("allowed_chats")
    assert_empty @state.read.fetch("access").fetch("ignored_users")
  end

  def test_access_mutation_and_command_receipt_are_one_durable_change
    update = stage
    before = @state.changes
    result = @access.command(update, "access", "users add 8")
    assert_equal before + 1, @state.changes
    persisted = Rho::IngressTelegram::State.new(store: TelegramStateSupport.document(@home)).read
    assert_equal ["8"], persisted.fetch("access").fetch("allowed_users")
    assert_equal "applied", persisted.fetch("pending_update").fetch("control_status")
    assert_equal result, persisted.fetch("pending_update").fetch("control_result")
    restarted = Rho::IngressTelegram::Access.new(settings: @settings, state: Rho::IngressTelegram::State.new(store: TelegramStateSupport.document(@home)))
    assert restarted.allowed?(8)
    command("access", "users remove 8")
    refute Rho::IngressTelegram::Access.new(settings: @settings,
      state: Rho::IngressTelegram::State.new(store: TelegramStateSupport.document(@home))).allowed?(8)
  end

  def test_groups_are_managed_independently_and_add_is_idempotent
    2.times { command("access", "chats add -10") }
    assert_equal ["-10"], @state.read.fetch("access").fetch("allowed_chats")
    assert @access.allowed_chat?(-10)
    refute @access.allowed?(10)
    assert_equal "Allowed groups: -10.", command("access", "chats list")
    command("access", "chats remove -10")
    refute @access.allowed_chat?(-10)
  end

  def test_ignore_wins_over_allow_and_removal_restores_existing_permission
    command("access", "users add 8")
    command("ignore", "add 8")
    refute @access.allowed?(8)
    assert @access.ignored?(8)
    command("access", "users add 8")
    refute @access.allowed?(8)
    assert_equal "Ignored users: 8.", command("ignore", "list")
    command("ignore", "remove 8")
    assert @access.allowed?(8)
    refute @access.ignored?(8)
    command("access", "users remove 8")
    refute @access.allowed?(8)
  end

  def test_owner_is_implicit_and_cannot_be_removed_or_ignored
    [["access", "users add 7"], ["access", "users remove 7"], ["ignore", "add 7"]].each do |name, argument|
      assert_includes command(name, argument), "cannot be removed or ignored"
    end
    assert_equal "Bot owner: 7.\nAllowed users: none.", command("access", "users list")
    assert @access.allowed?(7)
    refute @access.ignored?(7)
    assert_empty @state.read.fetch("access").fetch("ignored_users")
  end

  def test_invalid_grammar_and_ids_leave_lists_unchanged
    ["users add alice", "users add 0", "users add -8", "chats add 10", "chats add 0"].each do |argument|
      assert_includes command("access", argument), "numeric Telegram ID"
    end
    ["", "users", "users add", "users add 8 9", "users list 8", "owners add 8"].each do |argument|
      assert_equal Rho::IngressTelegram::Access::USAGE, command("access", argument)
    end
    assert_equal Rho::IngressTelegram::Access::USAGE, command("ignore", "add 8 9")
    assert_empty @state.read.fetch("access").fetch("allowed_users")
    assert_empty @state.read.fetch("access").fetch("allowed_chats")
    assert_empty @state.read.fetch("access").fetch("ignored_users")
  end

  def test_ignore_and_revoke_preserve_accepted_work_and_history
    original = { "requests" => { "request" => { "user_id" => "8", "status" => "accepted" } },
      "deliveries" => { "delivery" => { "status" => "pending", "text" => "An accepted answer" } },
      "messages" => { "-10:4:12" => { "request_id" => "request" } } }
    @state.change { |document| document.merge!(original) }
    command("access", "users add 8")
    command("ignore", "add 8")
    command("access", "users remove 8")
    refute @access.allowed?(8)
    original.each { |key, value| assert_equal value, @state.read.fetch(key) }
  end

  def test_local_management_changes_access_without_a_telegram_update
    @access.change(list: "allowed_users", action: "add", id: "0008")
    @access.change(list: "allowed_chats", action: "add", id: "-10")

    assert @access.allowed?(8)
    assert @access.allowed_chat?(-10)
    assert_nil @state.read["pending_update"]
    assert_nil @state.read["offset"]
    @access.change(list: "ignored_users", action: "add", id: "8")
    refute @access.allowed?(8)
    assert_equal ["8"], @access.document.fetch("ignored_users")
  end

  def test_local_management_rejects_invalid_ids_and_owner_changes
    [["allowed_users", "-8"], ["allowed_chats", "8"], ["ignored_users", "7"]].each do |list, id|
      assert_raises(Rho::ConfigurationError) { @access.change(list: list, action: "add", id: id) }
    end
    assert_raises(Rho::ConfigurationError) { @access.change(list: "owners", action: "add", id: "8") }
    assert_raises(Rho::ConfigurationError) { @access.change(list: "allowed_users", action: "replace", id: "8") }
    assert_equal 0, @state.changes
  end

  def test_revocation_discards_observation_source_without_changing_update_identity
    source = { "update_id" => 12, "user_id" => "8" }
    candidate = { "key" => "participation:12", "inference_request_id" => "one-shot" }
    @state.change do |document|
      document["offset"] = 15
      document.fetch("rooms")["-10:0"] = { "activity_update_id" => 12,
        "participation" => { "source" => source, "candidate" => candidate } }
    end

    @access.change(list: "allowed_users", action: "remove", id: "8")
    @access.change(list: "allowed_users", action: "add", id: "8")

    room = @state.read.fetch("rooms").fetch("-10:0")
    assert_nil room.fetch("participation")["source"]
    assert_equal candidate, room.fetch("participation").fetch("candidate")
    assert_equal 12, room.fetch("activity_update_id")
    assert_equal 15, @state.read.fetch("offset")
  end

  private

    def command(name, argument, **options)
      @access.command(stage(**options), name, argument)
    end

    def stage(user_id: 7, group: false)
      @update_id += 1
      document = { "update_id" => @update_id, "message" => { "message_id" => @update_id,
        "from" => { "id" => user_id }, "chat" => { "id" => group ? -10 : user_id, "type" => group ? "supergroup" : "private" } } }
      @state.consumed(@update_id - 1)
      @state.stage("update" => document)
      Rho::IngressTelegram::Update.new(document)
    end
end
