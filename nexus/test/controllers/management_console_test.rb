require "test_helper"

class ManagementConsoleTest < ActionDispatch::IntegrationTest
  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    @seam = create_run_backed_turn(conversation: @conversation, acting_user: @human)
    sign_in_as @human
  end

  test "Session authoring endpoints are retired rather than hidden behind navigation" do
    conversation = "/conversations/#{@conversation.public_id}"
    input = "#{conversation}/inputs/#{SecureRandom.uuid_v7}"
    schedule = "#{conversation}/schedules/#{SecureRandom.uuid_v7}"
    turn = "#{conversation}/turns/#{@seam.turn.public_id}"
    run = "/runs/#{@seam.run.public_id}"
    requests = [
      [:get, "/runs"], [:get, "/conversations"], [:get, "/conversations/new"], [:post, "/conversations"],
      [:post, "/conversations/preview"], [:post, "/uploads"], [:get, "/schedules"],
      [:get, "#{conversation}/inputs/new"], [:post, "#{conversation}/inputs"],
      [:get, "#{input}/edit"], [:patch, input], [:get, "#{conversation}/forks/new"],
      [:post, "#{conversation}/forks"], [:get, "#{turn}/regeneration/new"], [:post, "#{turn}/regeneration"],
      [:get, "#{turn}/variants/#{@seam.variant.public_id}/activation/new"],
      [:post, "#{turn}/variants/#{@seam.variant.public_id}/activation"],
      [:get, "#{run}/steers/new"], [:post, "#{run}/steers"], [:post, "#{run}/steers/#{SecureRandom.uuid_v7}/promotion"],
      [:get, "#{conversation}/schedules/new"], [:post, "#{conversation}/schedules"],
      [:get, "#{schedule}/edit"], [:patch, schedule], [:post, "#{conversation}/schedule_preview"],
    ]
    assert_no_difference ["Conversation.count", "Input.count", "Run.count", "Variant.count", "Schedule.count", "ContentUpload.count"] do
      requests.each do |method, path|
        public_send(method, path)
        assert_response :not_found, "#{method.upcase} #{path} must be retired"
      end
    end
  end

  test "Workspace Runs starts with standalone work and can include conversation runs" do
    standalone = Run.create!(workspace: @workspace, creating_user: @human, approval_mode: "bypass")
    get workspace_runs_path(@workspace)
    assert_response :success
    assert_select "article[data-run-id=?]", standalone.public_id
    assert_select "article[data-run-id=?]", @seam.run.public_id, count: 0
    assert_select "option[value=standalone][selected]"
    get workspace_runs_path(@workspace, kind: "all")
    assert_response :success
    assert_select "article[data-run-id=?]", standalone.public_id
    assert_select "article[data-run-id=?]", @seam.run.public_id
    assert_select "select[name=workspace_public_id]", count: 0
  end

  test "Workspace work pages share scoped navigation and cannot select an unauthorized scope" do
    [workspace_conversations_path(@workspace), workspace_runs_path(@workspace), workspace_schedules_path(@workspace)].each do |path|
      get path
      assert_response :success
      assert_select "nav a[href=?]", workspace_data_path(@workspace)
      assert_select "nav a[href=?]", workspace_settings_path(@workspace)
      assert_select "select[name='workspace_public_id']", count: 0
    end
    [workspace_conversations_path(workspaces(:personal)), workspace_runs_path(workspaces(:personal)),
      workspace_schedules_path(workspaces(:personal))].each do |path|
      get path
      assert_response :not_found
    end
  end
end
