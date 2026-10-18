require "test_helper"

class RunTaskAttachmentsTest < ActionDispatch::IntegrationTest
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @owner = users(:owner)
    @workspace = workspaces(:shared)
    sign_in_as @human
  end

  test "Tasks with no output or only structured output remain readable without an attachment list" do
    run = Run.create!(workspace: @workspace, creating_user: @owner, status: "running", approval_mode: "bypass")
    pending = run.tasks.create!(node_key: "pending", type: Tasks::ToolTask.sti_name,
      tool_name: "read_file", tool_input: {}, authored_by: "author")
    structured = run.tasks.create!(node_key: "structured", type: Tasks::ToolTask.sti_name,
      tool_name: "read_file", tool_input: {}, authored_by: "author")
    structured.update_columns(status: "completed", started_at: Time.current, completed_at: Time.current)
    result = ContentBodies::Replace.call(owner: structured, role: "output",
      entries: [{ "structured" => { "answer" => 42 } }], readable_text: "", seal: true)
    assert_predicate result, :accepted?

    [pending, structured].each do |task|
      get run_task_path(run, task.node_key)
      assert_response :success
      assert_select attachment_list, count: 0
    end
    assert_select "details pre", text: /"structured_content":\s*\{\s*"answer": 42/m
  end

  test "standalone Task captures use real metadata in content order with one link per upload" do
    run = standalone_run
    first = capture("first.txt", bytes: "first capture")
    second = capture("second.png", bytes: PngFixture.bytes(width: 40, height: 30), content_type: "image/png")
    unbound = capture("unbound.txt")
    task = captured_task(run, [second, first, second])

    get run_task_path(run, task.node_key)

    assert_response :success
    assert_select attachment_list do
      assert_select "li", count: 2
      assert_equal ["second.png", "first.txt"], css_select("a[href$='/bytes']").map(&:text)
      assert_select "a[href=?]", upload_bytes_path(upload_public_id: second.public_id), count: 1
      assert_select "a[href=?]", upload_bytes_path(upload_public_id: first.public_id), count: 1
      assert_select "a[href=?]", upload_preview_path(upload_public_id: second.public_id), count: 1
      assert_select "a[href=?]", upload_preview_path(upload_public_id: first.public_id), count: 0
      assert_select "span", text: "13 Bytes · text/plain"
      assert_select "span", text: /image\/png/
      assert_select "a", text: "Declared label", count: 0
      assert_select "span", text: /999999|application\/octet-stream/, count: 0
    end
    assert_select "a[href=?]", upload_bytes_path(upload_public_id: unbound.public_id), count: 0
    assert_select "details pre", text: /Declared label/

    get upload_bytes_path(upload_public_id: first.public_id)
    assert_response :success
    assert_equal "first capture", response.body
    get upload_bytes_path(upload_public_id: unbound.public_id)
    assert_response :not_found
  end

  test "a Conversation reader can download its Task capture until source access is withdrawn" do
    conversation, run = hosted_run
    upload = capture("answer.txt", bytes: "hosted capture")
    task = captured_task(run, [upload])

    get run_task_path(run, task.node_key)
    assert_response :success
    assert_select "a[href=?]", upload_bytes_path(upload_public_id: upload.public_id)
    get upload_bytes_path(upload_public_id: upload.public_id)
    assert_response :success
    assert_equal "hosted capture", response.body
    etag = response.headers.fetch("ETag")

    conversation.update!(access_default: "none")
    get run_task_path(run, task.node_key)
    assert_response :not_found
    get upload_bytes_path(upload_public_id: upload.public_id), headers: { "If-None-Match" => etag }
    assert_response :not_found
    get upload_preview_path(upload_public_id: upload.public_id)
    assert_response :not_found
  end

  test "standalone Task references lose read authority when Workspace access is withdrawn" do
    run = standalone_run
    upload = capture("standalone.txt")
    task = captured_task(run, [upload])

    get run_task_path(run, task.node_key)
    assert_response :success
    get upload_bytes_path(upload_public_id: upload.public_id)
    assert_response :success

    @workspace.update!(access_mode: "private")
    get run_task_path(run, task.node_key)
    assert_response :not_found
    get upload_bytes_path(upload_public_id: upload.public_id)
    assert_response :not_found
  end

  test "the upload creator keeps independent byte access after losing the Task reference" do
    conversation, run = hosted_run
    upload = @account.content_uploads.create!(creating_user: @human, file: blob("own.txt", "my capture", "text/plain"))
    task = captured_task(run, [upload])
    conversation.update!(access_default: "none")

    get run_task_path(run, task.node_key)
    assert_response :not_found
    get upload_bytes_path(upload_public_id: upload.public_id)
    assert_response :success
    assert_equal "my capture", response.body
  end

  test "an inherited attachment is readable without revealing its source Task" do
    conversation, run = hosted_run(access_default: "none")
    upload = capture("inherited.txt", bytes: "retained attachment")
    task = captured_task(run, [upload])
    message = ContentBodies::AttachedMessage.from_uploads(text: "Retained answer", uploads: [upload])
    ContentBodies::Replace.call(owner: run.variant, role: "content", entries: message.entries,
      uploads: message.uploads, readable_text: message.readable_text, seal: true)
    fork = Conversation.create!(workspace: @workspace, creating_user: @human)
    ConversationAncestry.create!(account: @account, conversation: fork, ancestor_conversation: conversation,
      depth: 1, boundary_position: run.turn.position)

    get conversation_turn_variant_path(fork, run.turn.public_id, run.variant.public_id)
    assert_response :success
    assert_select "a[href=?]", upload_bytes_path(upload_public_id: upload.public_id), text: "inherited.txt"
    assert_select "a[href^=?]", run_path(run), count: 0
    get upload_bytes_path(upload_public_id: upload.public_id)
    assert_response :success
    assert_equal "retained attachment", response.body
    get run_task_path(run, task.node_key)
    assert_response :not_found
  end

  test "pruned execution details retain the gone response without an attachment list" do
    run = standalone_run
    task = captured_task(run, [capture("expired.txt")])
    run.update!(details_pruned_at: Time.current)

    get run_task_path(run, task.node_key)

    assert_response :gone
    assert_select attachment_list, count: 0
  end

  test "a missing previewer leaves the original capture independently downloadable" do
    run = standalone_run
    upload = capture("page.pdf", bytes: PdfFixture::MINIMAL, content_type: "application/pdf")
    task = captured_task(run, [upload])

    ActiveStorage.stub(:previewers, []) do
      get run_task_path(run, task.node_key)
      assert_response :success
      assert_select "a[href=?]", upload_preview_path(upload_public_id: upload.public_id), count: 1
      get upload_preview_path(upload_public_id: upload.public_id)
    end
    assert_response :not_found
    assert_select "p", text: "representation_unavailable"
    get upload_bytes_path(upload_public_id: upload.public_id)
    assert_response :success
    assert_equal PdfFixture::MINIMAL.b, response.body.b
  end

  test "capture metadata loading uses the same number of queries for one and several files" do
    run = standalone_run
    one = captured_task(run, [capture("single.txt")], key: "single")
    many = captured_task(run, Array.new(4) { |i| capture("capture-#{i}.txt") }, key: "multiple")
    get run_task_path(run, one.node_key)
    assert_response :success

    single_queries = task_queries(run, one)
    multiple_queries = task_queries(run, many)

    assert_equal single_queries.length, multiple_queries.length, -> {
      "More captures must not add metadata or permission queries\n" \
        "One capture:\n#{single_queries.join("\n")}\nSeveral captures:\n#{multiple_queries.join("\n")}"
    }
    assert_select "#{attachment_list} li", count: 4
  end

  private

    def attachment_list = "ul[aria-label='#{I18n.t("conversation_console.attachments")}']"

    def standalone_run
      Run.create!(workspace: @workspace, creating_user: @owner, status: "completed", approval_mode: "bypass")
    end

    def hosted_run(access_default: "read")
      conversation = Conversation.create!(workspace: @workspace, creating_user: @owner, access_default: access_default)
      seam = create_run_backed_turn(conversation: conversation, acting_user: @owner,
        turn_status: "completed", variant_status: "completed", run_status: "completed")
      [conversation, seam.run]
    end

    def capture(filename, bytes: "capture bytes", content_type: "text/plain")
      @account.content_uploads.create!(creating_executor: executors(:address), file: blob(filename, bytes, content_type))
    end

    def blob(filename, bytes, content_type)
      ActiveStorage::Blob.create_and_upload!(io: StringIO.new(bytes), filename: filename,
        content_type: content_type, identify: false)
    end

    # Retained reader fixtures; executor settlement owns and separately tests
    # validation of the declared links and their bound upload set.
    def captured_task(run, uploads, key: "capture")
      task = run.tasks.create!(node_key: key, type: Tasks::ToolTask.sti_name,
        tool_name: "read_file", tool_input: {}, authored_by: "author")
      task.update_columns(status: "completed", started_at: Time.current, completed_at: Time.current)
      entries = [{ "text" => "Captured output" }] + uploads.map do |upload|
        { "resource_link" => { "uri" => "nexus://uploads/#{upload.public_id}", "name" => "Declared label",
          "mimeType" => "application/octet-stream", "size" => 999999 } }
      end
      result = ContentBodies::Replace.call(owner: task, role: "output", entries: entries,
        uploads: uploads.uniq, seal: true)
      assert_predicate result, :accepted?
      task
    end

    def task_queries(run, task)
      ApplicationRecord.connection_pool.clear_query_cache
      queries = []
      subscriber = ->(_name, _start, _finish, _id, payload) {
        queries << payload[:sql] unless payload[:cached] || %w[SCHEMA TRANSACTION].include?(payload[:name])
      }
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        get run_task_path(run, task.node_key)
      end
      assert_response :success
      queries
    end
end
