require "test_helper"

class ConversationManagementTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include RunLaneTestHelper

  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    @conversation = create_conversation(title: "A conversation", metadata: { "kept" => true })
    sign_in_as @human
  end

  test "title editing changes only the title and preserves the filtered list return" do
    return_to = workspace_conversations_path(@workspace, archived: "include",
      answering_user_public_id: @conversation.answering_user.public_id, query: "conversation")
    get edit_conversation_title_path(@conversation), params: { return_to: return_to }
    assert_response :success
    assert_equal "same-origin", response.headers["Referrer-Policy"]
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_select "meta[name='referrer'][content='same-origin']"
    assert_select "input[name='conversation[title]'][value='A conversation']"
    assert_select "input[name='conversation[lock_version]'][value=?]", @conversation.lock_version.to_s
    assert_select "input[name='return_to'][value=?]", return_to
    assert_back_link conversation_path(@conversation, return_to: return_to)

    assert_no_difference ["Turn.count", "Variant.count", "Run.count", "Input.count", "ModelInvocation.count"] do
      patch conversation_title_path(@conversation), params: { return_to: return_to,
        conversation: { title: "  Renamed conversation  ", lock_version: @conversation.lock_version,
          metadata: { "changed" => true }, cost_limit: "100", access_default: "none" } }
    end
    assert_redirected_to conversation_path(@conversation, return_to: return_to)
    assert_equal "Renamed conversation", @conversation.reload.title
    assert_equal({ "kept" => true }, @conversation.metadata)
    assert_equal "full", @conversation.access_default
    assert_nil @conversation.cost_limit
    follow_redirect!
    assert_select "h1", text: "Renamed conversation"
    assert_back_link return_to
  end

  test "title writes retain origin checks with CSRF protection enabled" do
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    https!

    fields = { conversation: { title: "Renamed conversation", lock_version: @conversation.lock_version } }
    assert_no_changes -> { @conversation.reload.title } do
      patch conversation_title_path(@conversation), params: fields,
        headers: { "Origin" => "https://other.example.com", "Sec-Fetch-Site" => "same-site" }
    end
    assert_response :unprocessable_entity

    patch conversation_title_path(@conversation), params: fields,
      headers: { "Origin" => request.base_url, "Sec-Fetch-Site" => "same-origin" }
    assert_response :see_other
    assert_equal "Renamed conversation", @conversation.reload.title
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end

  test "titles accept the length boundary and blank titles while validation preserves the draft" do
    update_title("界" * 255)
    assert_response :see_other
    assert_equal "界" * 255, @conversation.reload.title
    version = @conversation.lock_version
    update_title("界" * 256, version: version)
    assert_response :unprocessable_entity
    assert_select "input[name='conversation[title]'][value=?]", "界" * 256
    assert_select "input[name='conversation[lock_version]'][value=?]", version.to_s
    assert_equal "界" * 255, @conversation.reload.title
    update_title(" \n ")
    assert_response :see_other
    assert_nil @conversation.reload.title
    follow_redirect!
    assert_select "h1", text: I18n.t("conversation_console.untitled")
  end

  test "a stale title keeps its old version until explicit review and rejects another intervening edit" do
    old_version = @conversation.lock_version
    @conversation.update!(title: "First competing title")
    first_reviewed_version = @conversation.lock_version
    update_title("My draft", version: old_version)
    assert_response :conflict
    assert_select "input[name='conversation[title]'][value='My draft']"
    assert_select "input[name='conversation[lock_version]'][value=?]", old_version.to_s
    assert_select "input[name='conversation[reviewed_lock_version]'][value=?][required]", first_reviewed_version.to_s
    assert_select "[data-current-conversation-title]", text: "First competing title"
    assert_equal "First competing title", @conversation.reload.title

    @conversation.update!(title: "Second competing title")
    update_title("My draft", version: old_version, reviewed_version: first_reviewed_version)
    assert_response :conflict
    assert_select "input[name='conversation[lock_version]'][value=?]", old_version.to_s
    assert_select "[data-current-conversation-title]", text: "Second competing title"
    assert_equal "Second competing title", @conversation.reload.title

    update_title("My draft", version: old_version, reviewed_version: @conversation.lock_version)
    assert_response :see_other
    assert_equal "My draft", @conversation.reload.title
  end

  test "malformed and missing versions do not bypass title conflict checks" do
    [nil, "", "1.5", "-1", "2147483648"].each do |version|
      update_title("Rejected", version: version)
      assert_response :bad_request
      assert_equal "A conversation", @conversation.reload.title
    end
    update_title("Rejected", reviewed_version: "not a version")
    assert_response :bad_request
    assert_equal "A conversation", @conversation.reload.title
  end

  test "archiving after opening a title form refuses both further edits and its stale submission" do
    get edit_conversation_title_path(@conversation)
    assert_response :success
    version = @conversation.lock_version
    assert_predicate Conversations::Archive.call(conversation: @conversation), :accepted?
    update_title("Should not save", version: version)
    assert_response :conflict
    assert_includes response.body, I18n.t("conversation_management.title.archived")
    assert_equal "A conversation", @conversation.reload.title
    get edit_conversation_title_path(@conversation)
    assert_response :conflict
    get conversation_path(@conversation)
    assert_response :success
    assert_select "a[href^=?]", edit_conversation_title_path(@conversation), count: 0
    assert_select "a[href^=?]", new_conversation_unarchive_path(@conversation)
    get conversation_export_path(@conversation)
    assert_response :success
  end

  test "archive and restore synchronize the Subagent tree discard Sides and leave accepted execution alone" do
    child = create_conversation(parent_conversation: @conversation, parent_conversation_public_id: @conversation.public_id)
    grandchild = create_conversation(parent_conversation: child, parent_conversation_public_id: child.public_id)
    side = create_branch(source: child, side: true)
    branch = create_branch(source: @conversation)
    seam = create_run_backed_turn(conversation: @conversation, acting_user: @human)
    accepted = post_input!(@conversation.reload, acting_user: @human, text: "Queued before archive")
    return_to = workspace_conversations_path(@workspace, archived: "include")

    get new_conversation_archive_path(@conversation), params: { return_to: return_to }
    assert_response :success
    %w[scope side_effect accepted_work readable].each do |key|
      assert_includes response.body, I18n.t("conversation_management.archive.#{key}")
    end
    assert_back_link conversation_path(@conversation, return_to: return_to)
    post conversation_archive_path(@conversation), params: { return_to: return_to }
    assert_redirected_to conversation_path(@conversation, return_to: return_to)
    assert [@conversation, child, grandchild].all? { |row| row.reload.archived? }
    assert_not Conversation.exists?(side.id)
    assert_not branch.reload.archived?
    assert_equal "running", seam.run.reload.status
    assert_nil seam.run.stopped_at
    assert_equal "running", seam.turn.reload.status
    assert_equal "pending", accepted.reload.state
    follow_redirect!
    assert_back_link return_to
    assert_select "a[href^=?]", new_conversation_unarchive_path(@conversation)

    get new_conversation_unarchive_path(@conversation), params: { return_to: return_to }
    assert_response :success
    assert_includes response.body, I18n.t("conversation_management.unarchive.side_effect")
    post conversation_unarchive_path(@conversation), params: { return_to: return_to }
    assert_redirected_to conversation_path(@conversation, return_to: return_to)
    assert [@conversation, child, grandchild].none? { |row| row.reload.archived? }
    assert_not Conversation.exists?(side.id)
    assert_equal "running", seam.run.reload.status
    assert_nil seam.run.stopped_at
    assert_equal "pending", accepted.reload.state
  end

  test "an input accepted before the archive still materializes afterwards" do
    input = post_input!(@conversation, acting_user: @human, text: "Accepted before archive")
    post conversation_archive_path(@conversation)
    assert_response :see_other
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    assert_not Input.exists?(input.id)
    assert_equal "Accepted before archive", @conversation.turns.sole.active_variant.content_bodies.sole.effective_text
    assert_predicate @conversation.reload, :archived?
  end

  test "Subagent and Side lifecycle submissions keep the existing owner refusals" do
    child = create_conversation(parent_conversation: @conversation, parent_conversation_public_id: @conversation.public_id)
    side = create_branch(source: @conversation, side: true)
    [[child, :conflict, :subagent_follows_parent], [side, :unprocessable_entity, :side_conversation]].each do |row, status, refusal|
      get conversation_path(row)
      assert_response :success
      assert_select "a[href^=?]", new_conversation_archive_path(row), count: 0
      assert_select "a[href^=?]", new_conversation_unarchive_path(row), count: 0
      [conversation_archive_path(row), conversation_unarchive_path(row)].each do |path|
        post path
        assert_response status
        assert_includes response.body, I18n.t("conversation_management.refusals.#{refusal}")
        assert_not row.reload.archived?
      end
    end
  end

  test "current read-only concealed and tombstone scope governs every management door" do
    @conversation.update!(access_default: "read")
    assert_management_refused(:forbidden)
    get conversation_path(@conversation)
    assert_response :success
    assert_select "a[href^=?]", edit_conversation_title_path(@conversation), count: 0
    assert_select "a[href^=?]", new_conversation_archive_path(@conversation), count: 0
    @conversation.update!(access_default: "none")
    assert_management_refused(:not_found)
    @conversation.update!(access_default: "full", tombstoned_at: Time.current)
    assert_management_refused(:not_found)
  end

  test "account owner Workspace owner and Agent steward have no content bypass" do
    sign_out
    sign_in_as users(:owner)
    @conversation.update!(access_default: "read")
    assert_management_refused(:forbidden)
    @conversation.update!(access_default: "none")
    assert_management_refused(:not_found)
  end

  test "Workspace archive refuses management and restoring retains the existing live write contract" do
    result = Workspaces::Archive.call(workspace: @workspace, by: @workspace.owner, lock_version: @workspace.lock_version)
    assert_equal :accepted, result.outcome
    assert_management_refused(:forbidden)
    Workspaces::CompleteTransition.call(workspace: @workspace)
    assert_predicate @workspace.reload, :archived?
    assert_management_refused(:forbidden)
    result = Workspaces::Restore.call(workspace: @workspace, by: @workspace.owner, lock_version: @workspace.lock_version)
    assert_equal :accepted, result.outcome
    assert_predicate @workspace.reload, :restoring?
    update_title("While restoring")
    assert_response :see_other
    assert_equal "While restoring", @conversation.reload.title
    post conversation_archive_path(@conversation)
    assert_response :see_other
    post conversation_unarchive_path(@conversation)
    assert_response :see_other
  end

  test "management requires a browser session and external return locations fall back locally" do
    sign_out
    get edit_conversation_title_path(@conversation)
    assert_redirected_to new_session_path(return_to: edit_conversation_title_path(@conversation))
    sign_in_as @human
    update_title("Safe return", return_to: "https://elsewhere.invalid/conversations")
    assert_redirected_to conversation_path(@conversation, return_to: workspace_conversations_path(@workspace))
    post conversation_archive_path(@conversation), params: { return_to: "//elsewhere.invalid/" }
    assert_redirected_to conversation_path(@conversation, return_to: workspace_conversations_path(@workspace))
    post conversation_unarchive_path(@conversation), params: { return_to: "https://elsewhere.invalid/" }
    assert_redirected_to conversation_path(@conversation, return_to: workspace_conversations_path(@workspace))
  end

  private

    def create_conversation(**attributes)
      Conversation.create!(workspace: @workspace, creating_user: users(:curator),
        answering_user: users(:agent), **attributes)
    end

    def create_branch(source:, side: false)
      row = create_conversation(side: side)
      ConversationAncestry.create!(account: source.account, conversation: row,
        ancestor_conversation: source, depth: 1, boundary_position: -1)
      row
    end

    def update_title(title, version: @conversation.reload.lock_version, reviewed_version: nil, return_to: nil)
      patch conversation_title_path(@conversation), params: { return_to: return_to,
        conversation: { title: title, lock_version: version, reviewed_lock_version: reviewed_version } }
    end

    def assert_management_refused(status)
      [edit_conversation_title_path(@conversation), new_conversation_archive_path(@conversation),
        new_conversation_unarchive_path(@conversation)].each do |path|
        get path
        assert_response status
      end
      update_title("Unauthorized title")
      assert_response status
      [conversation_archive_path(@conversation), conversation_unarchive_path(@conversation)].each do |path|
        post path
        assert_response status
      end
      assert_equal "A conversation", @conversation.reload.title
      assert_not @conversation.archived?
    end

    def assert_back_link(path)
      assert_select "nav[aria-label=?] a[href=?]", I18n.t("shared.back_navigation.back"), path
    end
end
