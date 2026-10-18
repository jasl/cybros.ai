require "test_helper"
require "zlib"

class ConversationsConsoleTest < ActionDispatch::IntegrationTest
  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    @conversation = conversation(title: "Visible conversation")
    sign_in_as @human
  end

  test "session list applies workspace and conversation visibility before pagination" do
    hidden = conversation(creating_user: users(:owner), access_default: "none", title: "Concealed")
    deleted = conversation(title: "Deleted", tombstoned_at: Time.current)
    private_row = conversation(workspace: workspaces(:personal), title: "Private")
    side = conversation(side: true, title: "Side")
    child = conversation(parent_conversation: @conversation, parent_conversation_public_id: @conversation.public_id, title: "Child")
    archived = conversation(title: "Archived", archived_at: Time.current)
    get workspace_conversations_path(@workspace)
    assert_response :success
    assert_select "tr[data-conversation-id='#{@conversation.public_id}']", 1
    [hidden, deleted, private_row, side, child, archived].each do |row|
      assert_select "tr[data-conversation-id='#{row.public_id}']", 0
    end
    get workspace_conversations_path(@workspace), params: { archived: "only" }
    assert_response :success
    assert_select "tr[data-conversation-id='#{archived.public_id}']", 1
    assert_select "tr[data-conversation-id='#{@conversation.public_id}']", 0
    get workspace_conversations_path(workspaces(:personal))
    assert_response :not_found
  end

  test "sign in is required and account ownership does not grant concealed content" do
    concealed = conversation(access_default: "none")
    sign_out
    get conversation_path(@conversation)
    assert_redirected_to new_session_path(return_to: conversation_path(@conversation))
    sign_in_as users(:owner)
    [conversation_path(concealed), conversation_export_path(concealed), conversation_children_path(concealed)].each do |path|
      get path
      assert_response :not_found
    end
    @conversation.update!(archived_at: Time.current)
    get conversation_path(@conversation)
    assert_response :success
  end

  test "reader pages effective history, escapes content, and keeps the filtered return path" do
    turns = Array.new(23) { |index| append_message(@conversation, index == 22 ? "<script>alert('message')</script>" : "Message #{index}") }
    turns[1].update!(visibility: "hidden")
    return_to = workspace_conversations_path(@workspace, archived: "include")
    get conversation_path(@conversation), params: { return_to: return_to }
    assert_response :success
    assert_select "article[data-turn-id]", 20
    assert_select "article[data-turn-id='#{turns[1].public_id}']", 0
    assert_select "script", text: "alert('message')", count: 0
    assert_includes response.body, "&lt;script&gt;"
    assert_select "a[href=?]", return_to
    older_path = conversation_path(@conversation, before_position: turns[3].position, return_to: return_to)
    assert_select "a[href=?]", older_path
    get older_path
    assert_response :success
    assert_select "article[data-turn-id]", 2
    assert_back_link return_to
    get conversation_path(@conversation), params: { around_turn_public_id: turns[1].public_id }
    assert_response :not_found
  end

  test "Run inspection returns through the exact Conversation and candidate page to the filtered list" do
    seam = create_run_backed_turn(conversation: @conversation, acting_user: @human)
    list_path = workspace_conversations_path(@workspace, archived: "include")
    reader_path = conversation_path(@conversation, around_turn_public_id: seam.turn.public_id, return_to: list_path)
    execution_path = run_path(seam.run, return_to: reader_path)

    get reader_path
    assert_response :success
    assert_select "a[href=?]", execution_path, count: 2
    get execution_path
    assert_response :success
    assert_back_link reader_path
    get reader_path
    assert_back_link list_path

    candidates_path = conversation_turn_variants_path(@conversation, seam.turn.public_id, return_to: reader_path)
    assert_select "a[href=?]", candidates_path
    get candidates_path
    assert_response :success
    assert_back_link reader_path
    candidate_execution_path = run_path(seam.run, return_to: candidates_path)
    assert_select "a[href=?]", candidate_execution_path
    get candidate_execution_path
    assert_response :success
    assert_back_link candidates_path
  end

  test "inherited content and candidate deck do not reveal an unreadable source Run" do
    seam = create_run_backed_turn(conversation: @conversation, acting_user: @human,
      turn_status: "completed", variant_status: "completed", run_status: "completed")
    ContentBodies::Replace.call(owner: seam.variant, role: "content", entries: [{ "text" => "Inherited answer" }], seal: true)
    fork = conversation(creating_user: users(:curator), title: "Fork")
    ConversationAncestry.create!(account: @conversation.account, conversation: fork,
      ancestor_conversation: @conversation, depth: 1, boundary_position: seam.turn.position)
    @conversation.update!(access_default: "none")
    sign_out
    sign_in_as users(:curator)
    get conversation_path(fork)
    assert_response :success
    assert_includes response.body, "Inherited answer"
    assert_not_includes response.body, seam.run.public_id
    assert_select "a[href^=?]", conversation_path(@conversation), count: 0
    get conversation_turn_variants_path(fork, seam.turn.public_id)
    assert_response :success
    assert_includes response.body, "Inherited answer"
    assert_not_includes response.body, seam.run.public_id
    fork.turn_overrides.create!(turn: seam.turn, visibility: "hidden")
    get conversation_turn_variants_path(fork, seam.turn.public_id)
    assert_response :not_found
  end

  test "candidate decks and related collections are bounded and filtered" do
    turn = append_message(@conversation, "First answer")
    22.times do |index|
      Variant.create!(turn: turn, position: index + 1, status: "completed", source: "manual")
    end
    reader_path = conversation_path(@conversation, around_turn_public_id: turn.public_id,
      return_to: workspace_conversations_path(@workspace, archived: "include"))
    get conversation_turn_variants_path(@conversation, turn.public_id), params: { return_to: reader_path }
    assert_response :success
    assert_select "[data-variant-id]", 20
    assert_back_link reader_path
    get response.parsed_body.at_css("a[rel='next']")["href"]
    assert_response :success
    assert_select "[data-variant-id]", 3
    assert_back_link reader_path
    20.times { conversation(parent_conversation: @conversation, parent_conversation_public_id: @conversation.public_id) }
    child = conversation(parent_conversation: @conversation, parent_conversation_public_id: @conversation.public_id)
    hidden = conversation(creating_user: users(:owner), access_default: "none",
      parent_conversation: @conversation, parent_conversation_public_id: @conversation.public_id)
    branch = conversation
    side = conversation(side: true)
    [branch, side].each do |row|
      ConversationAncestry.create!(account: @conversation.account, conversation: row,
        ancestor_conversation: @conversation, depth: 1, boundary_position: turn.position)
    end
    { conversation_children_path(@conversation, return_to: reader_path) => child,
      conversation_branches_path(@conversation, return_to: reader_path) => branch,
      conversation_sides_path(@conversation, return_to: reader_path) => side }.each do |path, row|
      get reader_path
      assert_select "a[href=?]", path
      get path
      assert_response :success
      assert_back_link reader_path
      assert_select "tr[data-conversation-id='#{row.public_id}']", 1
      assert_select "tr[data-conversation-id='#{hidden.public_id}']", 0
      row_path = conversation_path(row, return_to: path)
      assert_select "a[href=?]", row_path
      get row_path
      assert_response :success
      assert_back_link path
      assert_select "a[href=?]", conversation_path(@conversation, return_to: row_path)
    end
    get conversation_children_path(@conversation), params: { return_to: reader_path }
    assert_select "tr[data-conversation-id]", 20
    get response.parsed_body.at_css("a[rel='next']")["href"]
    assert_response :success
    assert_select "tr[data-conversation-id]", 1
    assert_back_link reader_path
  end

  test "workspace search reuses effective history and opens the exact field with its context" do
    visible = append_message(@conversation, "A searchable nebula")
    hidden = append_message(@conversation, "An invisible nebula")
    hidden.update!(visibility: "hidden")
    get workspace_conversations_path(@workspace), params: { query: "nebula" }
    assert_response :success
    assert_includes response.body, "searchable nebula"
    assert_not_includes response.body, "invisible nebula"
    target = response.parsed_body.at_css("a[href*='/fields/content']")["href"]
    assert_includes target, "/turns/#{visible.public_id}/variants/#{visible.active_variant.public_id}/fields/content"
    get target
    assert_response :success
    assert_select "[data-history-field='content']", text: /searchable nebula/
    assert_select "a[href*=?]", "around_turn_public_id=#{visible.public_id}"
    get "/conversations", params: { query: "nebula" }
    assert_response :not_found
  end

  test "search keeps answerer archive query and return filters while the form resets old cursors" do
    @conversation.update!(archived_at: Time.current)
    21.times { |index| append_message(@conversation, "filterneedle #{index}") }
    other = conversation(answering_user: users(:agent), title: "filterneedle wrong answerer", archived_at: Time.current)
    append_message(other, "filterneedle excluded answer")
    list = workspace_conversations_path(@workspace, query: "filterneedle",
      archived: "only", answering_user_public_id: @human.public_id)
    get list
    assert_response :success
    assert_not_includes response.body, "wrong answerer"
    assert_not_includes response.body, "excluded answer"
    assert_select "select[name='answering_user_public_id'] option[value=?][selected]", @human.public_id
    assert_select "form input[name='after'], form input[name='page']", count: 0
    more = response.parsed_body.css("a").find { |link| link.text == I18n.t("conversation_console.more_results") }["href"]
    query = Rack::Utils.parse_query(URI.parse(more).query)
    assert_equal @human.public_id, query.fetch("answering_user_public_id")
    assert_equal "only", query.fetch("archived")
    assert_equal "filterneedle", query.fetch("query")
    target = response.parsed_body.at_css("a[href*='/fields/content']")["href"]
    get target
    assert_response :success
    assert_back_link list
    get more
    assert_response :success
    assert_select "a[href*='/fields/content']", 1
    assert_select "form input[name='after'], form input[name='page']", count: 0
  end

  test "retained answer states pruned execution and diagnostic export uses the same cookie authority" do
    seam = create_run_backed_turn(conversation: @conversation, acting_user: @human,
      turn_status: "completed", variant_status: "completed", run_status: "completed")
    seam.variant.update!(details_pruned_at: Time.current)
    seam.run.update!(details_pruned_at: Time.current)
    ContentBodies::Replace.call(owner: seam.variant, role: "content", entries: [{ "text" => "Retained answer" }], seal: true)
    get conversation_path(@conversation)
    assert_response :success
    assert_includes response.body, "Retained answer"
    assert_includes response.body, I18n.t("conversation_console.details_pruned")
    get conversation_export_path(@conversation)
    assert_response :success
    assert_equal "application/gzip", response.media_type
    assert_includes response.headers.fetch("Cache-Control"), "no-store"
    contents = Zlib::GzipReader.new(StringIO.new(response.body)).read
    assert_includes contents, "Retained answer"
  end

  test "background input is collapsed by origin while ordinary text and the reply stay visible" do
    wrapper = '<task_result task="background-job">Finished report</task_result>'
    ordinary = append_message(@conversation, wrapper)
    actor = Speakers::Resolve.member(account: @conversation.account, user: @human)
    callback = @conversation.turns.create!(position: @conversation.timeline_position_head,
      kind: "direct_reply", role: "assistant", origin: "task_result", status: "completed",
      speaker: actor, control_owner_user: @human)
    variant = callback.variants.create!(position: 0, status: "completed", source: "run")
    ContentBodies::Replace.call(owner: variant, role: "prompt", entries: [{ "text" => wrapper }], seal: true)
    ContentBodies::Replace.call(owner: variant, role: "content", entries: [{ "text" => "Here is the finished report." }], seal: true)
    callback.update!(active_variant: variant)
    @conversation.update!(timeline_position_head: callback.position + 1)

    get conversation_path(@conversation)
    assert_response :success
    assert_select "article[data-turn-id='#{ordinary.public_id}'] summary", text: I18n.t("conversation_console.background_input"), count: 0
    assert_select "article[data-turn-id='#{callback.public_id}'] details:not([open]) summary", text: I18n.t("conversation_console.background_input")
    assert_select "article[data-turn-id='#{callback.public_id}'] > div > [data-controller='work-content'] .prose", text: /Here is the finished report/

    get conversation_turn_variants_path(@conversation, callback.public_id)
    assert_response :success
    assert_select "details:not([open]) summary", text: I18n.t("conversation_console.background_input")
    get conversation_turn_variant_path(@conversation, callback.public_id, variant.public_id)
    assert_response :success
    assert_select "details:not([open]) summary", text: I18n.t("conversation_console.background_input")
  end

  private

    def assert_back_link(path)
      assert_select "nav[aria-label=?] a[href=?]", I18n.t("shared.back_navigation.back"), path
    end

    def conversation(**attributes)
      Conversation.create!(workspace: @workspace, creating_user: @human, **attributes)
    end

    def append_message(conversation, text)
      speaker = Speakers::Resolve.member(account: conversation.account, user: @human)
      turn = conversation.turns.create!(position: conversation.timeline_position_head,
        kind: "message", role: "user", status: "completed", speaker: speaker, control_owner_user: @human)
      variant = turn.variants.create!(position: 0, status: "completed", source: "manual")
      ContentBodies::Replace.call(owner: variant, role: "content", entries: [{ "text" => text }], seal: true)
      turn.update!(active_variant: variant)
      conversation.update!(timeline_position_head: turn.position + 1)
      turn
    end
end
