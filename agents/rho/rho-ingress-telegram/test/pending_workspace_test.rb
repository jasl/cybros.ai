require "support/runtime"

class TelegramPendingWorkspaceTest < Minitest::Test
  include TelegramRuntimeSupport

  def test_pending_child_controls_keep_the_source_workspace_after_switch_and_restart
    @runtime.consume(telegram_message(1, "start"))
    @bridge.pending_rows = %w[allow deny ask].map do |key|
      { "workspace_public_id" => "workspace-home", "run_public_id" => "child-loop", "task_key" => key,
        "kind" => key == "ask" ? "ask" : "approval", "question" => "Review this request" }
    end
    @runtime.tick
    questions = @state.read.fetch("questions")
    assert_equal ["workspace-home"] * 3, questions.values.map { |row| row.fetch("workspace_public_id") }
    @runtime.consume(telegram_message(2, "/workspace use workspace-project"))
    @bridge.default_workspace = @bridge.workspace_rows.last
    @state = Rho::IngressTelegram::State.new(store: TelegramStateSupport.document(@home))
    @runtime = runtime

    %w[allow deny ask].each_with_index do |key, index|
      id = @state.read.fetch("questions").find { |_id, row| row.fetch("task_key") == key }.first
      command = { "allow" => "approve", "deny" => "deny", "ask" => "answer" }.fetch(key)
      @runtime.consume(telegram_message(index + 3, "/#{command} #{id} yes"))
    end

    assert_equal [["approve", "child-loop", "allow", "workspace-home"],
      ["deny", "child-loop", "deny", "workspace-home"],
      ["answer", "child-loop", "ask", "yes", "workspace-home"]], @bridge.decisions
    assert_equal "workspace-project", @state.read.fetch("routes").fetch("1:0").fetch("workspace_public_id")
    assert_equal "workspace-project", @bridge.default_workspace.fetch("public_id")
    assert @state.read.fetch("questions").values.all? { |row| row.fetch("resolved") }
  end
end
