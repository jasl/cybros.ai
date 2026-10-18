require "test_helper"

class BotCommandsTest < Minitest::Test
  include RhoTest::CliHarness

  BOT = { "public_id" => "bot-1", "name" => "helper", "handle" => "helper-2" }.freeze
  CURRENT = { "public_id" => "c-current", "workspace_public_id" => "ws-home" }.freeze
  PREVIOUS = { "public_id" => "c-old", "workspace_public_id" => "ws-old" }.freeze

  def bots(*args, **options) = Rho::Extensions::Agents::Commands.bots(cli, args, options)

  def serve_bots(routes, rows: [BOT])
    @seen = []
    announce(endpoint: recording_routed_endpoint(@seen,
      { "GET /agents" => [[200, { "bots" => rows }]] }.merge(routes)))
  end

  def posted(path)
    JSON.parse(@seen.find { |request| request.start_with?("POST #{path} ") }.partition("\r\n\r\n").last)
  end

  def test_current_resolves_an_own_bot_and_uses_the_shared_current_operation
    sibling = BOT.merge("public_id" => "bot-other", "from" => "another-rho")
    serve_bots({ "POST /bots/current" => [[200, { "selected" => CURRENT, "current" => CURRENT, "replayed" => false }]] }, rows: [sibling, BOT])

    result = bots("current", "helper", "operation-id": "open-once")

    assert_equal CURRENT, result.fetch("current")
    assert_equal({ "agent_public_id" => "bot-1", "operation_id" => "open-once" }, posted("/bots/current"))
    assert_equal ["operation: open-once", "selected: c-current  workspace: ws-home"], @out.string.lines.map(&:chomp)
  end

  def test_new_prints_its_generated_operation_before_a_refusal_so_it_can_be_retried
    serve_bots({ "POST /bots/new" => [[409, { "error" => { "code" => "bot_home_required", "message" => "Choose a Home Workspace" } }]] })

    error = assert_raises(Rho::Core::Refused) { bots("new", "@helper-2") }

    assert_equal "bot_home_required", error.code
    operation = posted("/bots/new").fetch("operation_id")
    assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[0-9a-f]{4}-[0-9a-f]{12}\z/, operation)
    assert_equal "operation: #{operation}\n", @out.string
    assert_equal "bot-1", posted("/bots/new").fetch("agent_public_id")
  end

  def test_resume_uses_the_recorded_workspace_and_shows_a_later_current_on_replay
    serve_bots({ "POST /bots/resume" => [[200, { "selected" => PREVIOUS, "current" => CURRENT, "replayed" => true }]] })

    bots("resume", "bot-1", "c-old", workspace: "ws-old", "operation-id": "resume-once")

    assert_equal({ "agent_public_id" => "bot-1", "operation_id" => "resume-once",
      "conversation_public_id" => "c-old", "workspace_public_id" => "ws-old" }, posted("/bots/resume"))
    assert_equal ["operation: resume-once", "selected: c-old  workspace: ws-old",
      "current: c-current  workspace: ws-home", "replayed: true"], @out.string.lines.map(&:chomp)
  end

  def test_history_preserves_each_workspace_and_pagination_without_switching
    rows = [CURRENT.merge("title" => "Today"), PREVIOUS.merge("title" => "Earlier", "archived_at" => "2026-10-12T00:00:00Z")]
    serve_bots({ "GET /bots/history?agent_public_id=bot-1&after=page-1&limit=2" => [[200,
      { "conversations" => rows, "pagination" => { "next_after" => "page-2" } }]] })

    bots("history", "helper", after: "page-1", limit: 2)

    assert_equal ["c-current  workspace: ws-home  open  Today", "c-old  workspace: ws-old  archived  Earlier",
      "next: --after page-2"], @out.string.lines.map(&:chomp)
    assert_empty @seen.grep(/\APOST /)
  end

  def test_empty_history_is_reported_without_creating_a_conversation
    serve_bots({ "GET /bots/history?agent_public_id=bot-1" => [[200, { "conversations" => [], "pagination" => { "next_after" => nil } }]] })

    bots("history", "helper")

    assert_equal "(no Bot conversations)\n", @out.string
    assert_empty @seen.grep(/\APOST /)
  end

  def test_missing_arguments_are_reported_before_contacting_the_daemon
    assert_match(/takes current/, assert_raises(Rho::Error) { bots("unknown", "helper") }.message)
    assert_match(/needs BOT/, assert_raises(Rho::Error) { bots("new") }.message)
    assert_match(/CONVERSATION_ID/, assert_raises(Rho::Error) { bots("resume", "helper") }.message)
    assert_match(/--workspace/, assert_raises(Rho::Error) { bots("resume", "helper", "c-old") }.message)
    assert_match(/Home Workspace/, assert_raises(Rho::Error) { bots("new", "helper", workspace: "ws-other") }.message)
  end

  def test_other_applications_and_plugin_definitions_cannot_be_selected
    serve_bots({}, rows: [BOT.merge("from" => "another-rho"), BOT.merge("public_id" => "plugin", "registered" => true)])

    assert_match(/No editable Bot/, assert_raises(Rho::Error) { bots("current", "helper") }.message)
    assert_empty @seen.grep(/\APOST /)
  end
end
