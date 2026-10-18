require "test_helper"

class Runs::ImagesTest < ActiveJob::TestCase
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @agent.update!(image_model: "dev/mock-image", fallback_models: ["dev/mock-text"])
    executors(:address).update!(status: "revoked")
  end

  test "offline image work captures only its image route and shares the ordinary invocation lifecycle" do
    run = image_run
    @agent.update!(image_model: nil)
    call, child = generate(run)

    assert child, call.output_body.effective_text
    assert_equal "completed", call.status
    assert_equal "image_generate", call.tool_name
    assert_nil AgentAPI::RunPresenter.task(call)[:target]
    assert_equal "image_generation", child.workload
    assert_equal "branch", child.continuation_source
    assert_nil child.input_from_node_keys
    assert_nil child.system_instructions
    assert_nil child.compaction
    assert_empty Array(child.tool_definitions)
    assert_empty child.fallback_models
    assert_nil child.operation_context
    invocation = child.selected_model_invocation
    assert_equal "image_generation", invocation.workload
    assert_equal "mock-image", invocation.model_ref
    refute invocation.request_options.key?("tools")
    refute invocation.request_options.key?("instructions")
    request = invocation.content_bodies.find_by!(role: "request")
    assert_equal [{ "text" => "Draw a small blue bird." }], request.entry_payloads
    assert_equal "queued", task(run, "r1").status
    assert_nil Executor.address_for(@agent)
  end

  test "generated resource links retain the validated blob and repeated convergence creates no duplicate uploads" do
    run = image_run
    call, child = generate(run)
    attempt = attempt_for(child)
    apply_via(attempt, image_success)
    blob = attempt.model_invocation.reload.output_files.sole.blob
    assert_difference -> { ContentUpload.count }, 1 do
      Runs::ConvergeTerminalSteps.call
    end
    child.reload
    detail = AgentAPI::RunPresenter.task_detail(child, live_server_ids: [])
    link = detail.fetch(:content).find { |entry| entry.fetch(:type) == "resource_link" }
    upload = ContentUpload.find_by!(public_id: link.fetch(:uri).delete_prefix("nexus://uploads/"))
    assert_equal blob, upload.file.blob
    assert_equal "image/png", link.fetch(:mimeType)
    assert_equal png_bytes, upload.file.download
    assert upload.readable_by?(@human)
    assert Executors::Attachments.bound?(upload, run)

    assert_no_difference -> { ContentUpload.count } do
      2.times { Runs::ConvergeTerminalSteps.call }
      assert_equal :not_running, Runs::Images::Generate.call(node: call)
    end
    attempt.model_invocation.output_files.purge
    assert_equal png_bytes, upload.reload.file.download, "the task's upload owns the same blob after invocation detail purge"
    schedule(run)
    assert_equal "running", task(run, "r1").status
    assert_includes task(run, "r1").selected_model_invocation.content_bodies.find_by!(role: "request").effective_text,
      upload.public_id
  end

  test "an absent image model refuses without creating provider work" do
    @agent.update!(image_model: nil)
    run = image_run
    call, child = generate(run)
    assert_nil child
    assert call.output_summary.fetch("is_error")
    assert_includes call.output_body.effective_text, "image_model_required"
    assert_equal 0, run.model_invocations.where(workload: "image_generation").count
    assert_equal 2, run.model_invocations.where(workload: "text_generation").count,
      "the text continuation reads the refusal without attempting image generation"
  end

  test "an expired tool never appends or dispatches image work" do
    run = image_run
    call, child = generate(run) { |node| node.update!(await_started_at: 2.days.ago) }

    assert_equal "timed_out", call.status
    assert_nil child
    assert_empty run.model_invocations.where(workload: "image_generation")
  end

  test "an authored task with the image child suffix cannot stand for another call's work" do
    run = image_run(model("r1t0-model-1"))
    unrelated = task(run, "r1t0-model-1")

    call, child = generate(run)
    assert child, call.output_body.effective_text
    refute_equal unrelated, child
    assert_nil unrelated.reload.expansion_parent
    assert_equal "image_generation", child.reload.selected_model_invocation.workload
    assert_equal "queued", unrelated.reload.status
    assert_no_difference -> { run.tasks.count } do
      assert_equal :not_running, Runs::Images::Generate.call(node: call)
    end
  end

  test "reference images preserve ordered occurrences and never accept an unbound upload" do
    first = image_upload
    second = image_upload
    ids = [second.public_id, first.public_id, second.public_id]
    snapshot = ModelCatalog.current
    model = snapshot.models.fetch("dev/mock-image")
    image = model.merge("capabilities" => model.fetch("capabilities").merge("input_modalities" => ["image"]))
    catalog = snapshot.with(models: snapshot.models.merge("dev/mock-image" => image))
    ModelCatalog.stub(:current, catalog) do
      run = image_run(attachments: [first.public_id, second.public_id])
      _call, child = generate(run, "reference_upload_public_ids" => ids)
      assert_equal ids, child.input_body.upload_parts.map(&:public_id)
      request = child.selected_model_invocation.content_bodies.find_by!(role: "request")
      assert_equal ids, request.request_uploads("image_generation").map(&:public_id)
      assert_equal 2, request.content_body_uploads.count
    end

    call, child = generate(image_run, "reference_upload_public_ids" => [first.public_id])
    assert_nil child
    assert_includes call.output_body.effective_text, "reference_upload_unavailable"
  end

  test "Stop fences a late provider response without publishing output" do
    run = image_run
    _call, child = generate(run)
    attempt = attempt_for(child)
    built = build(attempt)
    started = start(attempt)
    fake_dispatch(image_success) do
      outcome = ModelInvocations::Dispatch.call(attempt: started.attempt, context: started.context, request: built.request)
      assert_predicate Runs::Stop.call(Runs::Stop::Command.forced(run: run, acting_user: @human)), :accepted?
      assert_no_difference -> { ContentUpload.count } do
        ModelInvocations::ApplyResult.call(attempt: started.attempt, outcome: outcome)
        Runs::ConvergeTerminalSteps.call
      end
    end
    assert_equal "canceled", child.reload.status
    assert_nil child.output_body
    assert_empty attempt.model_invocation.reload.output_files
  end

  test "forced Pause requeues an image under a new generation and stale completion remains fenced" do
    run = image_run
    _call, child = generate(run)
    old_invocation = child.selected_model_invocation
    result = Runs::Pause.call(Runs::Pause::Command.new(run: run, acting_user: @human, force: true))
    assert_predicate result, :accepted?
    Runs::ConvergeTerminalSteps.call
    assert_equal "queued", child.reload.status
    assert_equal 1, child.execution_generation
    assert_predicate Runs::Resume.call(Runs::Resume::Command.new(run: run, acting_user: @human)), :accepted?
    schedule(run)
    refute_equal old_invocation.id, child.reload.selected_model_invocation_id
    assert_no_difference -> { ContentUpload.count } do
      run.with_lock { Runs::ApplyStepResult.call(run: run, invocation: old_invocation) }
    end
    assert_equal "running", child.reload.status
  end

  private

    def image_run(*following, attachments: nil)
      root = model("round", "prompt" => "Make an image.", "instructions" => "Text system prompt.",
        "tools" => [Nexus::ToolRegistry.function_definition("image_generate")])
      root.fetch("model")["attachments"] = attachments if attachments
      run = seed(root, *following, creating_user: @agent, default_runner_executor_public_id: nil)
      assert_predicate Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: @human)), :accepted?
      schedule(run)
      run
    end

    def generate(run, **fields)
      input = { "prompt" => "Draw a small blue bird." }.merge(fields)
      apply_via(attempt_for(task(run, "round")), sse_success("Drawing", tool_calls: [
        { id: "image-call", name: "image_generate", arguments: input.to_json },
      ]))
      Runs::ConvergeTerminalSteps.call
      schedule(run)
      call = task(run, "r1t0")
      yield call if block_given?
      Runs::Images::Generate.call(node: call)
      schedule(run)
      [call.reload, run.tasks.find_by(expansion_parent: call, type: Tasks::ModelTask.sti_name)]
    end

    def task(run, key) = run.tasks.find_by!(node_key: key)
    def schedule(run) = Runs::ScheduleReady.call(run_id: run.id)

    def attempt_for(node)
      ModelInvocations::AdmitQueuedWork.call
      node.reload.selected_model_invocation.attempts.order(:id).last
    end

    def image_success
      json_response(200, { "created" => 0, "data" => [{ "b64_json" => [png_bytes].pack("m0") }] })
    end

    def image_upload
      @account.content_uploads.create!(creating_user: @agent,
        file: ActiveStorage::Blob.create_and_upload!(io: StringIO.new(png_bytes), filename: "pixel.png", content_type: "image/png"))
    end
end
