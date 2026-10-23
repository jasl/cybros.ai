require_relative "turn_test"

class TurnTest
  def test_lifecycle_hooks_cross_the_executor_boundary_and_continue_before_final_delivery
    hook = { "tool" => "lifecycle_check", "timeout_ms" => 30_000 }
    boot_rho!(settings: { "plugins" => { "rho.lifecycle_hooks" => { "configuration" => {
      "turn_start" => hook, "stop" => hook.merge("max_continuations" => 1),
    } } } }, extensions: [File.expand_path("../support/lifecycle_extension.rb", __dir__)])
    conversation, loop_id = rho_open("!mock -- first candidate")
    context = rho_loops.run(loop_id)
    completed = await_rho_loop(loop_id, "completed")
    hooks = completed.tasks.select { |task| task.tool_name == "lifecycle_check" }
      .map { |task| context.task(task.key) }

    assert_equal %w[turn_start stop stop], hooks.map { |detail| detail.tool_input.fetch("event") }
    assert hooks.all? { |detail| detail.task.status == "completed" && detail.task.claimed_by }
    assert_equal [true, false], hooks.drop(1).map { |detail| detail.structured_content.fetch("continue") }
    assert_includes context.task(completed.deliverable_task_key).output, "lifecycle-feedback-verified"
    assert_equal 1, steward_conversation(conversation).turns.list.items.count { |turn| turn.kind == "direct_reply" },
      "hook feedback continues the same reply execution"
  end

  def test_compaction_hooks_bracket_the_repair_before_the_next_model_request
    hook = { "tool" => "lifecycle_check", "timeout_ms" => 30_000 }
    boot_rho!(settings: { "plugins" => { "rho.lifecycle_hooks" => {
      "configuration" => { "pre_compact" => hook, "post_compact" => hook },
    } } },
      extensions: [File.expand_path("../support/lifecycle_extension.rb", __dir__)])
    arguments = CGI.escape(JSON.generate("command" => "printf 'compaction source'"))
    _conversation, loop_id = rho_open("!mock usage=9000:5 tool_call=bash tool_args=#{arguments} -- continue")
    context = rho_loops.run(loop_id)
    completed = await_rho_loop(loop_id, "completed")
    hooks = completed.tasks.select { |task| task.tool_name == "lifecycle_check" }
      .map { |task| context.task(task.key) }

    assert_equal %w[pre_compact post_compact], hooks.map { |detail| detail.tool_input.fetch("event") }
    assert hooks.all? { |detail| detail.task.status == "completed" && detail.task.claimed_by }
    assert_includes context.task(completed.deliverable_task_key).output,
      "This summary replaces earlier history"
  end

  private
end
