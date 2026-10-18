require "test_helper"

class DiagnosticExportConnectionTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
  end

  teardown do
    @run&.destroy!
    Conversation.find_by(id: @conversation&.id)&.destroy!
  end

  test "Run diagnostics release read connections before every compressed chunk" do
    seam = create_run_backed_turn(conversation: @conversation, acting_user: @human)
    @run = seam.run
    body = AgentAPI::RunExport.new(run: @run, user: @human)
    assert_released_stream(body)
  end

  test "Workspace data releases read connections before every compressed chunk" do
    assert_released_stream(Workspaces::DataExport.new(workspace: @workspace))
  end

  private

    def assert_released_stream(body)
      pool = ApplicationRecord.connection_pool
      pool.release_connection
      chunks = 0
      body.each do |_chunk|
        assert_nil pool.active_connection?, "a slow reader must not retain a database connection"
        chunks += 1
      end
      assert_operator chunks, :>, 1
      assert_nil pool.active_connection?
    end
end
