require "test_helper"

class Workspaces::MessagingTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:shared)
    @agent = users(:agent)
    @sender = create_agent_member(display_name: "Research agent")
    @other = create_agent_member(display_name: "Writing agent")
    sign_in_as users(:owner)
  end

  test "the addressable page explains Public by default and offers agents with workspace access" do
    get workspace_path(@workspace)
    assert_select "a[href=?]", workspace_settings_path(@workspace), text: "Settings"
    get workspace_settings_path(@workspace)
    assert_select "a[href=?]", workspace_messaging_path(@workspace), text: "View messaging settings"

    get workspace_messaging_path(@workspace, agent_public_id: @agent.public_id)

    assert_response :success
    assert_select "h1", text: "Agent messaging"
    assert_select "body", text: /Agents are Public by default/
    assert_select "body", text: /automatic result replies still return/
    assert_select "body", text: /incoming contact only/
    assert_select "input[name='messaging[mode]'][value='public'][checked]"
    assert_select "input[name='messaging[lock_version]'][value=?]", @workspace.lock_version.to_s
    assert_select "input[type='checkbox'][value=?]", @sender.public_id
    assert_select "input[type='checkbox'][value=?]", @agent.public_id, count: 0
    assert_select "option[value=?]", users(:owner).public_id, count: 0
    assert_select "option[value=?]", users(:system).public_id, count: 0
  end

  test "saving one agent limits incoming contact and preserves the other agent settings" do
    @workspace.update!(messaging_policy: { agents: [settings_for(@other)] })

    put workspace_messaging_path(@workspace), params: form_for(@agent, senders: [@sender.public_id])

    assert_redirected_to workspace_messaging_path(@workspace, agent_public_id: @agent.public_id)
    assert @workspace.reload.messaging_allowed?(sender: @sender, recipient: @agent)
    assert_not @workspace.messaging_allowed?(sender: @other, recipient: @agent)
    assert @workspace.messaging_allowed?(sender: @agent, recipient: @sender)
    assert_not @workspace.messaging_allowed?(sender: @sender, recipient: @other)
  end

  test "Public keeps the Private allowlist for switching back" do
    @workspace.update!(messaging_policy: { agents: [settings_for(@agent, [@sender])] })

    put workspace_messaging_path(@workspace), params: form_for(
      @agent, mode: "public", senders: [@sender.public_id]
    )

    assert_redirected_to workspace_messaging_path(@workspace, agent_public_id: @agent.public_id)
    assert @workspace.reload.messaging_allowed?(sender: @other, recipient: @agent)
    assert_equal [@sender.public_id], @workspace.messaging_policy.agents.first.allowed_sender_public_ids
    follow_redirect!
    assert_select "input[name='messaging[mode]'][value='public'][checked]"
    assert_select "input[type='checkbox'][value=?][checked]", @sender.public_id

    put workspace_messaging_path(@workspace), params: form_for(@agent, senders: [@sender.public_id])

    assert @workspace.reload.messaging_allowed?(sender: @sender, recipient: @agent)
    assert_not @workspace.messaging_allowed?(sender: @other, recipient: @agent)
  end

  test "an empty Private list permits contact only from the agent itself" do
    put workspace_messaging_path(@workspace), params: form_for(@agent, senders: [""])

    assert_redirected_to workspace_messaging_path(@workspace, agent_public_id: @agent.public_id)
    assert @workspace.reload.messaging_allowed?(sender: @agent, recipient: @agent)
    assert_not @workspace.messaging_allowed?(sender: @sender, recipient: @agent)
    follow_redirect!
    assert_select "[data-agent-id=?] li", @agent.public_id, text: "Itself", count: 1
    assert_select "input[name='messaging[mode]'][value='private'][checked]"
  end

  test "a stale edit keeps the selection and refreshes only the reported version" do
    original_version = @workspace.lock_version
    @workspace.update!(messaging_policy: { agents: [settings_for(@other)] })

    put workspace_messaging_path(@workspace), params: form_for(
      @agent, senders: [@sender.public_id], version: original_version
    )

    assert_response :conflict
    assert_select "[role='alert']", text: /changed elsewhere/
    assert_select "input[type='checkbox'][value=?][checked]", @sender.public_id
    assert_select "input[name='messaging[mode]'][value='private'][checked]"
    assert_select "input[name='messaging[lock_version]'][value=?]", @workspace.reload.lock_version.to_s
    assert_equal [@other.public_id], @workspace.messaging_policy.agents.map(&:agent_public_id)
  end

  test "invalid senders keep the submitted choices and do not change the policy" do
    put workspace_messaging_path(@workspace), params: form_for(
      @agent, senders: [users(:owner).public_id]
    )

    assert_response :unprocessable_entity
    assert_select "[role='alert']", text: /could not be saved/
    assert_select "input[type='checkbox'][value=?][checked]", users(:owner).public_id
    assert_empty @workspace.reload.messaging_policy.agents
  end

  test "an invalid edit does not silently adopt a newer version" do
    original_version = @workspace.lock_version
    invalid = @workspace.dup
    invalid.errors.add(:messaging_policy, :invalid)
    result = ::Workspaces::Mutation::Result.invalid(invalid)

    ::Workspaces::UpdateMessaging.stub(:call, lambda { |**|
      @workspace.update!(name: "Changed elsewhere")
      result
    }) do
      put workspace_messaging_path(@workspace), params: form_for(
        @agent, senders: [@sender.public_id], version: original_version
      )
    end

    assert_response :unprocessable_entity
    assert_select "input[name='messaging[lock_version]'][value=?]", original_version.to_s
    assert_select "input[type='checkbox'][value=?][checked]", @sender.public_id
    assert_select "body", text: /Changed elsewhere/
  end

  test "invalid agent and mode selectors cannot clear existing settings" do
    @workspace.update!(messaging_policy: { agents: [settings_for(@agent)] })

    put workspace_messaging_path(@workspace), params: form_for(users(:owner), mode: "public")
    assert_response :unprocessable_entity
    assert_select "[role='alert']", text: /Choose an agent/

    put workspace_messaging_path(@workspace), params: form_for(@agent, mode: "unknown")
    assert_response :unprocessable_entity
    assert_select "[role='alert']", text: /Choose Public or Private/
    assert_equal [@agent.public_id], @workspace.reload.messaging_policy.agents.map(&:agent_public_id)
  end

  test "a reader sees the policy but cannot change it" do
    @workspace.update!(messaging_policy: { agents: [settings_for(@agent, [@sender])] })
    sign_out
    sign_in_as users(:member)

    get workspace_messaging_path(@workspace)
    assert_response :success
    assert_select "[data-agent-id=?]", @agent.public_id, text: /Research agent/
    assert_select "[data-agent-id=?]", @agent.public_id, text: /Private/
    assert_select "body", text: /Only the workspace owner/
    assert_select "form[action=?]", workspace_messaging_path(@workspace), count: 0

    put workspace_messaging_path(@workspace), params: form_for(@agent, mode: "public")
    assert_redirected_to workspace_path(@workspace)
    assert_equal I18n.t("workspaces.not_owner"), flash[:alert]
    assert_equal "private", @workspace.reload.messaging_policy.agents.first.mode
  end

  test "private workspaces stay concealed and sign in is required" do
    get workspace_messaging_path(workspaces(:personal))
    assert_response :not_found
    put workspace_messaging_path(workspaces(:personal)), params: form_for(@agent)
    assert_response :not_found

    sign_out
    get workspace_messaging_path(@workspace)
    assert_redirected_to new_session_path(return_to: workspace_messaging_path(@workspace))
  end

  test "archived workspaces retain readable policy without an editor" do
    ::Workspaces::Archive.call(workspace: @workspace, by: users(:owner), lock_version: @workspace.lock_version)
    ::Workspaces::CompleteTransition.call(workspace: @workspace)

    get workspace_messaging_path(@workspace)
    assert_response :success
    assert_select "form[action=?]", workspace_messaging_path(@workspace), count: 0
    put workspace_messaging_path(@workspace), params: form_for(@agent)
    assert_redirected_to workspace_path(@workspace)
    assert_equal I18n.t("workspaces.not_active"), flash[:alert]
  end

  test "a retained unavailable agent remains visible and can return to Public" do
    @workspace.update!(messaging_policy: { agents: [settings_for(@agent, [@sender])] })
    @agent.remove

    get workspace_messaging_path(@workspace, agent_public_id: @agent.public_id)
    assert_response :success
    assert_select "[data-agent-id=?]", @agent.public_id, text: /Fixture Agent/
    assert_select "input[name='messaging[mode]'][value='private'][checked]"

    put workspace_messaging_path(@workspace), params: form_for(
      @agent, mode: "public", senders: [@sender.public_id]
    )
    assert_redirected_to workspace_messaging_path(@workspace, agent_public_id: @agent.public_id)
    assert_equal "public", @workspace.reload.messaging_policy.agents.first.mode
    assert_equal [@sender.public_id], @workspace.messaging_policy.agents.first.allowed_sender_public_ids
  end

  test "the messaging form root is required" do
    put workspace_messaging_path(@workspace), params: { unrelated: "value" }
    assert_response :bad_request
  end

  test "missing and malformed versions cannot edit an initial policy" do
    assert_equal 0, @workspace.lock_version
    fields = form_for(@agent).fetch(:messaging)
    fields.delete(:lock_version)
    put workspace_messaging_path(@workspace), params: { messaging: fields }
    assert_response :bad_request

    [nil, "", "not-a-version", "0junk", -1, 2_147_483_648].each do |version|
      put workspace_messaging_path(@workspace), params: form_for(@agent, version: version)
      assert_response :bad_request
    end
    assert_empty @workspace.reload.messaging_policy.agents
    assert_equal 0, @workspace.lock_version
  end

  private

    def settings_for(agent, senders = [], mode: "private")
      { agent_public_id: agent.public_id, mode: mode, allowed_sender_public_ids: senders.map(&:public_id) }
    end

    def form_for(agent, mode: "private", senders: [], version: @workspace.lock_version)
      { messaging: {
        agent_public_id: agent.public_id, mode: mode,
        allowed_sender_public_ids: senders, lock_version: version,
      } }
    end
end
