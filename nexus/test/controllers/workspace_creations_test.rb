require "test_helper"

class WorkspaceCreationsTest < ActionDispatch::IntegrationTest
  setup do
    @member = users(:member)
    sign_in_as @member
  end

  test "the form defaults to Private and offers Account-wide without an owner selector" do
    get new_workspace_path

    assert_response :success
    assert_select "h1", text: "New workspace"
    assert_select "form[action=?]", workspaces_path do
      assert_select "input[name='workspace[name]'][maxlength='100']"
      assert_select "input[name='workspace[access_mode]'][value='private'][checked]"
      assert_select "input[name='workspace[access_mode]'][value='account_wide']:not([checked])"
      assert_select "input[name='workspace[owner_id]']", count: 0
      assert_select "input[name='workspace[agent_identifier]']", count: 0
    end
  end

  test "an ordinary Human creates a private workspace owned by themselves" do
    assert_difference -> { Workspace.count }, 1 do
      post workspaces_path, params: { workspace: { name: "Research" } }
    end

    workspace = Workspace.find_by!(owner: @member, name: "Research")
    assert_response :see_other
    assert_redirected_to workspace_path(workspace)
    assert_equal @member, workspace.creator
    assert_equal @member.account, workspace.account
    assert_predicate workspace, :private?
    assert_nil workspace.agent_identifier
    assert_empty workspace.metadata
    assert_equal I18n.t("workspaces.create.created"), flash[:notice]
  end

  test "explicit Account-wide creation retains Human ownership and ignores ownership claims" do
    post workspaces_path, params: {
      workspace: { name: "Team research", access_mode: "account_wide", owner_id: users(:owner).id,
        agent_identifier: "claimed-program" },
    }

    workspace = Workspace.find_by!(owner: @member, name: "Team research")
    assert_redirected_to workspace_path(workspace)
    assert_predicate workspace, :account_wide?
    assert_equal @member, workspace.creator
    assert_nil workspace.agent_identifier
    assert_predicate workspace, :active?
    assert workspace.data_accessible_by?(users(:owner))
    assert_not workspace.manageable_by?(users(:owner))
  end

  test "invalid names preserve the access choice and create nothing" do
    assert_no_difference -> { Workspace.count } do
      post workspaces_path, params: { workspace: { name: " ", access_mode: "account_wide" } }
    end

    assert_response :unprocessable_entity
    assert_select "[role='alert']", text: /could not be created/
    assert_select "input[name='workspace[name]'][value=' '][aria-invalid='true']"
    assert_select "input[value='account_wide'][checked]"
    assert_select "body", text: /Name can't be blank/
  end

  test "an invalid access choice keeps the name and creates nothing" do
    assert_no_difference -> { Workspace.count } do
      post workspaces_path, params: { workspace: { name: "Research", access_mode: "public" } }
    end

    assert_response :unprocessable_entity
    assert_select "input[name='workspace[name]'][value='Research']"
    assert_select "#workspace-access-errors", text: /Choose Private or Account-wide/
    assert_select "input[type='radio'][checked]", count: 0
  end

  test "signed-out users must sign in before creating a workspace" do
    sign_out

    get new_workspace_path
    assert_redirected_to new_session_path(return_to: new_workspace_path)
    assert_no_difference -> { Workspace.count } do
      post workspaces_path, params: { workspace: { name: "Not signed in" } }
    end
    assert_redirected_to new_session_path
  end
end
