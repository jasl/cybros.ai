require "support/runtime"

class TelegramArchivedWorkspaceTest < Minitest::Test
  include TelegramRuntimeSupport

  # The daemon forgets a followed host on archive; a later unscoped request
  # then uses its selected default. The conversation remains readable in A.
  class ScopedBridge < TelegramRuntimeSupport::Bridge
    attr_reader :scope_calls

    def initialize
      super
      @scope_calls, @remembered = [], {}
    end

    def open(**options)
      id = super
      @remembered[id] = options.fetch(:workspace_public_id)
      id
    end

    def archive(id)
      @remembered.delete(id)
      @current = { "status" => "completed", "archived_at" => "2026-09-30" }
    end

    def turns(id, after_position:, workspace_public_id: nil)
      check_scope(:turns, id, workspace_public_id)
      super(id, after_position: after_position)
    end

    def turn_source(id, position:, workspace_public_id: nil)
      check_scope(:turn_source, id, workspace_public_id)
      super(id, position: position)
    end

    def conversation(id, workspace_public_id: nil)
      check_scope(:conversation, id, workspace_public_id)
      super
    end

    def inputs(id = nil, workspace_public_id: nil)
      check_scope(:inputs, id, workspace_public_id) if id
      super
    end

    def snapshot(id, workspace_public_id: nil, run: nil, inputs: nil)
      check_scope(:snapshot, id, workspace_public_id)
      super
    end

    def pending(id, workspace_public_id: nil, reads: nil)
      check_scope(:pending, id, workspace_public_id)
      super(id)
    end

    def submit(id, workspace_public_id: nil, **options)
      check_scope(:submit, id, workspace_public_id)
      super(id, workspace_public_id: workspace_public_id, **options)
    end

    def stop(id, workspace_public_id: nil, **options)
      check_scope(:stop, id, workspace_public_id)
      super(id, **options)
    end

    private

      def check_scope(operation, id, explicit)
        selected = explicit || @remembered[id] || @default_workspace.fetch("public_id")
        @scope_calls << [operation, id, selected]
        expected = @open_workspaces[id] || @loop_workspaces.fetch(id)
        if selected != expected
          raise Rho::Core::Refused.new("Not found in selected workspace", code: "not_found", status: 404)
        end
      end
  end

  def test_archived_conversation_keeps_original_scope_after_default_changes_and_local_follow_is_forgotten
    @bridge = ScopedBridge.new
    @runtime = runtime
    @runtime.consume(telegram_message(1, "Start in A"))
    @state.change { |document| document.fetch("deliveries").clear }
    @bridge.default_workspace = @bridge.workspace_rows.last
    @bridge.archive("conversation-1")
    @bridge.turn_rows["conversation-1"] = [turn(0, "Readable archived answer")]
    @bridge.scope_calls.clear
    @runtime = runtime
    @runtime.tick

    route = @state.read.fetch("routes").fetch("1:0")
    assert route.fetch("conversations").key?("conversation-1"), "archive is not read access loss"
    assert @client.calls.any? { |_method, parameters| parameters[:text] == "Readable archived answer" }
    assert_equal %i[turns snapshot pending turn_source], @bridge.scope_calls.map(&:first)
    assert_equal ["workspace-home"], @bridge.scope_calls.map(&:last).uniq
    assert_equal "workspace-home", route.fetch("conversations").fetch("conversation-1").fetch("workspace_public_id")

    # After the owner restores the source, requests and controls keep A too.
    @bridge.current = { "status" => "running", "run_public_id" => "loop-1" }
    @runtime.consume(telegram_message(2, "Continue after restoration"))
    @runtime.consume(telegram_message(3, "/status"))
    @runtime.consume(telegram_message(4, "/stop"))
    assert_equal %i[submit conversation inputs snapshot pending stop], @bridge.scope_calls.last(6).map(&:first)
    assert_equal ["workspace-home"], @bridge.scope_calls.map(&:last).uniq
    status = @state.read.fetch("deliveries").fetch("control:3").fetch("text")
    assert_includes status, "Workspace: Home (workspace-home)"
    assert_includes status, "Conversation: conversation-1"
    assert_equal 2, @bridge.inputs.length
    assert_equal ["loop-2"], @bridge.stops
    assert_equal "workspace-project", @bridge.default_workspace.fetch("public_id")
  end
end
