require "test_helper"
require "rho/schedule_commands"

class CoreSchedulesTest < Minitest::Test
  include RhoTest::CliHarness

  def test_commands_resolve_relative_intent_once_and_preserve_daily_civil_time
    once = Rho::ScheduleCommands.parse("create once in 30m Report progress", now: 0)
    assert_equal({ "kind" => "once", "run_at" => "1970-01-01T00:30:00Z" }, once.fields.fetch(:rule))
    interval = Rho::ScheduleCommands.parse("create every 2h Report progress", now: 0)
    assert_equal({ "kind" => "interval", "every_seconds" => 7200, "starts_at" => "1970-01-01T02:00:00Z" }, interval.fields.fetch(:rule))
    daily = Rho::ScheduleCommands.parse("create daily 09:00 Asia/Shanghai Report progress", now: 0)
    assert_equal({ "kind" => "daily", "local_time" => "09:00", "time_zone" => "Asia/Shanghai" }, daily.fields.fetch(:rule))
    assert_equal "Report progress", daily.fields.fetch(:prompt)
    assert_raises(Rho::Error) { Rho::ScheduleCommands.parse("create every 0s Report", now: 0) }
    assert_raises(Rho::Error) { Rho::ScheduleCommands.parse("edit job every 1h extra", now: 0) }
  end

  def test_core_round_trips_scope_and_retry_identity_without_omitting_explicit_clears
    seen = []
    row = { "public_id" => "job", "lock_version" => 4 }
    announce(endpoint: recording_routed_endpoint(seen,
      "POST /conversations/schedules/create" => [[201, { "schedule" => row }]],
      "POST /conversations/schedules/update" => [[200, { "schedule" => row }]],
      "GET /conversations/schedules/detail" => [[200, { "schedule" => row }]],
      "GET /conversations/schedules/executions" => [[200, { "executions" => [], "pagination" => { "last_cursor" => "tail" } }]]))
    command = Rho::ScheduleCommands.parse("create once in 1h Report progress", now: 0)
    assert_equal row, Rho::ScheduleCommands.execute(core, "chat", command,
      workspace_public_id: "original", model: "dev/model", idempotency_key: "intent-1", to: "agent", speaker_public_id: "speaker")
    create = JSON.parse(seen.grep(/\APOST /).last.partition("\r\n\r\n").last)
    assert_equal %w[chat original intent-1], create.values_at("public_id", "workspace_public_id", "idempotency_key")
    assert_equal %w[agent speaker], create.values_at("to", "speaker_public_id")
    assert_equal "1970-01-01T01:00:00Z", create.dig("rule", "run_at")
    core.update_schedule("chat", "job", expected_lock_version: 4, name: nil, tool_names: [],
      reasoning_enabled: false, workspace_public_id: "original")
    update = JSON.parse(seen.grep(/\APOST /).last.partition("\r\n\r\n").last)
    assert_nil update.fetch("name")
    assert_equal [], update.fetch("tool_names")
    assert_equal false, update.fetch("reasoning_enabled")
    refute update.key?("prompt")
    assert_equal "tail", core.schedule_executions("chat", "job", after: "tail", workspace_public_id: "original").dig("pagination", "last_cursor")
    query = URI.decode_www_form(URI.parse(seen.grep(%r{\AGET /conversations/schedules/executions}).last.lines.first.split[1]).query).to_h
    assert_equal %w[original tail job], query.values_at("workspace_public_id", "after", "job_public_id")
  end

  def test_edit_uses_the_read_version_and_surfaces_conflict_without_retry
    seen = []
    announce(endpoint: recording_routed_endpoint(seen,
      "GET /conversations/schedules/detail" => [[200, { "schedule" => { "lock_version" => 7 } }]],
      "POST /conversations/schedules/update" => [[409, { "error" => { "code" => "stale_object", "message" => "Job changed" } }]]))
    command = Rho::ScheduleCommands.parse("edit job prompt Revised task", now: 0)
    assert_raises(Rho::Error) { Rho::ScheduleCommands.execute(core, "chat", command) }
    writes = seen.grep(/\APOST /)
    assert_equal 1, writes.length
    assert_equal 7, JSON.parse(writes.first.partition("\r\n\r\n").last).fetch("expected_lock_version")
  end

  def test_create_preserves_an_explicit_reasoning_switch_beside_effort
    seen = []
    announce(endpoint: recording_routed_endpoint(seen,
      "POST /conversations/schedules/create" => [[201, { "schedule" => { "public_id" => "job" } }]]))

    core.create_schedule("chat", prompt: "Report progress", rule: { "kind" => "once" },
      model: "dev/model", reasoning_enabled: false, reasoning_effort: "low", idempotency_key: "intent")

    fields = JSON.parse(seen.grep(/\APOST /).last.partition("\r\n\r\n").last)
    assert_equal false, fields.fetch("reasoning_enabled")
    assert_equal "low", fields.fetch("reasoning_effort")
  end

  def test_product_command_prints_job_and_execution_states_without_conflating_them
    row = { "public_id" => "job", "prompt" => "Report", "status" => "completed", "rule" => { "kind" => "once" },
      "last_execution" => { "status" => "running", "child_conversation_public_id" => "child" } }
    announce(endpoint: routed_endpoint(
      "GET /conversations/schedules/detail" => [[200, { "schedule" => row }]],
      "GET /conversations/schedules/executions" => [[200, { "executions" => [
        { "child_conversation_public_id" => "child", "status" => "running", "scheduled_for" => "2026-10-02T09:00:00Z" },
      ], "pagination" => { "next_after" => "next" } }]]))
    Rho::Extensions::Ops::JobRoutes.command(cli, %w[chat show job], {})
    assert_includes @out.string, "job · schedule: completed"
    assert_includes @out.string, "Latest execution: running · child"
    @out.truncate(0)
    @out.rewind
    Rho::Extensions::Ops::JobRoutes.command(cli, %w[chat history job], {})
    assert_includes @out.string, "child · running"
    assert_includes @out.string, "history job next"
    @out.truncate(0)
    @out.rewind
    Rho::Extensions::Ops::JobRoutes.command(cli, %w[chat show job], { json: true })
    assert_equal row, JSON.parse(@out.string)
  end
end
