require "test_helper"

class WorkReadingTest < ActionDispatch::IntegrationTest
  include ActiveRecord::Assertions::QueryAssertions

  setup do
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    sign_in_as @human
  end

  test "exact results render Markdown and preserve captured configuration after the Agent changes" do
    variant = direct_reply(configuration: captured_configuration)
    @agent.update!(default_model: "fixture/new", conversation_reach: "workspace")
    get conversation_turn_variant_path(@conversation, variant.turn.public_id, variant.public_id)

    assert_response :success
    assert_select "[data-work-content-target=body] h2", text: "Readable result"
    assert_select "[data-work-content-target=body] strong", text: "Answer"
    assert_select "pre code[data-clipboard-target=source]", text: /# Readable result/
    assert_select "section[aria-label='Captured execution configuration']" do
      assert_select "dd", text: "fixture/initial", count: 2
      assert_select "dd", text: "subtree"
      assert_select "pre", text: /Captured prompt text/
      assert_select "pre", text: /fixture\/backup/
      assert_select "pre", text: /fixture\/new/, count: 0
    end
  end

  test "missing configuration and collected execution details retain available historical model facts" do
    variant = direct_reply(configuration: nil)
    get conversation_turn_variant_path(@conversation, variant.turn.public_id, variant.public_id)
    assert_response :success
    assert_select "section[aria-label='Captured execution configuration']" do
      assert_select "dd", text: "fixture/initial", count: 2
      assert_select "p", text: "No captured configuration is available for this execution."
    end

    seam = create_run_backed_turn(conversation: @conversation, acting_user: @human,
      turn_status: "completed", variant_status: "completed", run_status: "completed",
      agent_configuration: captured_configuration)
    seam.run.update!(details_pruned_at: Time.current,
      retained_model: Run::RetainedModel.new(provider_id: "fixture", model_ref: "terminal"))
    get run_path(seam.run)
    assert_response :success
    assert_select "section[aria-label='Captured execution configuration'] dd", text: "fixture/terminal"
    assert_select "section[aria-label='Captured execution configuration'] pre", text: /Captured prompt text/
    assert_select "section[aria-label='Transcript']", count: 0
  end

  test "persisted deeply nested content stays readable and escaped on Conversation readers" do
    seam = create_run_backed_turn(conversation: @conversation, acting_user: @human,
      turn_status: "completed", variant_status: "completed", run_status: "completed")
    text = "> " * 1_000 + "<script>window.untrustedReadingExecuted = true</script>\r\n  exact & spaced\r"
    ContentBodies::Replace.call(owner: seam.variant, role: "content", entries: [{ "text" => text }], seal: true)

    [conversation_path(@conversation), conversation_turn_variant_path(@conversation, seam.turn.public_id, seam.variant.public_id)].each do |path|
      get path
      assert_response :success
      content = "[data-variant-id='#{seam.variant.public_id}']"
      assert_equal text, css_select("#{content} [data-work-content-target=body] pre code").first.text
      assert_equal text, css_select("#{content} details pre code").first.text
      assert_select "#{content} script, #{content} blockquote", count: 0
    end
  end

  test "readable inherited content cannot reveal hidden source configuration or a current configuration link" do
    [false, true].each do |run_backed|
      source = Conversation.create!(workspace: @workspace, creating_user: users(:owner), answering_user: @agent,
        access_default: "none")
      if run_backed
        seam = create_run_backed_turn(conversation: source, acting_user: users(:owner),
          turn_status: "completed", variant_status: "completed", run_status: "completed",
          agent_configuration: captured_configuration)
        variant = seam.variant
        write_answer(variant)
      else
        variant = direct_reply(configuration: captured_configuration, conversation: source)
      end
      fork = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
      ConversationAncestry.create!(account: source.account, conversation: fork,
        ancestor_conversation: source, depth: 1, boundary_position: variant.turn.position)

      get conversation_turn_variant_path(fork, variant.turn.public_id, variant.public_id)
      assert_response :success
      assert_select "h2", text: "Readable result"
      assert_not_includes response.body, "Captured prompt text"
      assert_select "a[href^=?]", agent_configuration_path(@agent), count: 0
      assert_select "a[href^=?]", run_path(seam.run), count: 0 if run_backed
      assert_select "section[aria-label='Captured execution configuration'] dd", text: "fixture/initial", count: 0
    end
  end

  test "Run and exact candidate retain approval and reach when the configuration document is missing" do
    @agent.update!(conversation_reach: "subtree")
    seam = create_run_backed_turn(conversation: @conversation, acting_user: @human,
      turn_status: "completed", variant_status: "completed", run_status: "completed", approval_mode: "ask")
    @agent.update!(conversation_reach: "workspace")

    [run_path(seam.run), conversation_turn_variant_path(@conversation, seam.turn.public_id, seam.variant.public_id)].each do |path|
      get path
      assert_response :success
      assert_select "section[aria-label='Captured execution configuration']" do
        assert_select "dd", text: "ask"
        assert_select "dd", text: "subtree"
        assert_select "p", text: "No captured configuration is available for this execution."
      end
    end
  end

  test "attention previews only the authorized page and does not materialize complete bodies" do
    first = attention_run
    second = attention_run
    first_question = question(first, "question", "甲" * 280 + "PRIVATE TAIL")
    question(second, "question", "SECOND PAGE CONTENT")

    assert_no_queries_match(/SELECT "content_bodies"\.\*|FROM "content_fragments"/) do
      get attention_path, params: { limit: 1 }
    end
    assert_response :success
    assert_select "article[data-task-key='#{first_question.node_key}']", count: 1
    assert_includes response.body, "甲" * 280
    assert_not_includes response.body, "PRIVATE TAIL"
    assert_not_includes response.body, "SECOND PAGE CONTENT"
    assert_select "article p", text: /Preview truncated/
    next_page = css_select("a").find { |link| link.text == "Next page" }["href"]
    get next_page
    assert_response :success
    assert_includes response.body, "SECOND PAGE CONTENT"
    assert_not_includes response.body, "甲" * 280
  end

  test "attention displays a shared virtual wait and completed failure age without invented starts" do
    travel_to Time.utc(2026, 10, 16, 12) do
      run = attention_run
      run.update!(status: "paused", paused_at: 2.minutes.ago)
      waiting = question(run, "waiting", "Paused question")
      waiting.update!(await_started_at: 5.minutes.ago)
      failed = question(run, "failed", "No longer waiting")
      failed.update!(status: "failed", completed_at: 10.minutes.ago, error_key: "await_timeout", error_detail: "Please retry")

      get attention_path
      assert_response :success
      assert_select "article[data-task-key=waiting]", text: /Effective wait: 3 minutes/
      assert_select "article[data-task-key=failed]", text: /Failure recorded 10 minutes ago/
      assert_select "article[data-task-key=failed]", text: /await_timeout: Please retry/
      accounts(:cybros).update!(maintenance_started_at: 4.minutes.ago)
      get attention_path
      assert_response :success
      assert_select "article[data-task-key=waiting]", text: /Effective wait: 1 minute/
    end
  end

  test "fixed usage summary preserves a safe return and scopes its separate download" do
    window = { from: "2026-10-10T00:00:00.000000Z", to: "2026-10-12T00:00:00.000000Z" }
    overview = workspace_path(@workspace)
    usage_link = usage_path(**window, workspace_public_id: @workspace.public_id, return_to: overview)
    get usage_link
    assert_response :success
    assert_select "nav a[href=?]", overview
    assert_select "form[action=?] input[name=workspace_public_id][value=?]", usage_export_path, @workspace.public_id
    assert_select "input[name=return_to]", count: 0
    get usage_path, params: window.merge(return_to: "https://external.test/", provider_id: "fixture")
    assert_response :success
    assert_select "input[name=return_to]", count: 0
    assert_select "nav a[href='https://external.test/']", count: 0
  end

  private

    def captured_configuration
      AgentConfiguration.new(default_model: "fixture/initial", approval_mode: "ask", tool_definitions: [],
        conversation_reach: "subtree", fallback_models: ["fixture/backup"],
        system_prompt: { content: "Captured prompt text", role: "system" })
    end

    def direct_reply(configuration:, conversation: @conversation)
      turn = conversation.turns.create!(position: conversation.timeline_position_head,
        kind: "direct_reply", role: "assistant", status: "completed",
        speaker: Speakers::Resolve.member(account: conversation.account, user: @agent),
        control_owner_user: conversation.creating_user, answering_user: @agent)
      variant = turn.variants.create!(position: 0, status: "completed", source: "inference",
        provider_id: "fixture", model_ref: "initial", agent_configuration: configuration,
        model_selection: ModelSelectionIntent.explicit("fixture/initial"), fallback_models: ["fixture/backup"])
      turn.update!(active_variant: variant)
      conversation.update!(timeline_position_head: turn.position + 1)
      write_answer(variant)
      variant
    end

    def write_answer(variant)
      ContentBodies::Replace.call(owner: variant, role: "content",
        entries: [{ "text" => "# Readable result\n\n**Answer**\n\n```ruby\nputs 1\n```" }], seal: true)
    end

    def attention_run
      Run.create!(workspace: @workspace, creating_user: @human, status: "running", approval_mode: "bypass")
    end

    def question(run, key, text)
      task = run.tasks.create!(type: Tasks::AwaitTask.sti_name, node_key: key, authored_by: "model", on_failure: "halt")
      task.update!(status: "awaiting_input", started_at: Time.current, await_started_at: Time.current)
      ContentBodies::Replace.call(owner: task, role: "input", entries: [{ "text" => text }], seal: true)
      task
    end
end
