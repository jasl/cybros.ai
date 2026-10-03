# Drives the REAL invocation chain — acceptance, admission, the start claim,
# request build, dispatch — and fakes only the HTTP adapter, because hand-built
# rows are how two shipped bugs stayed invisible (the terminal-apply lesson).
# Includers' setup must set @account and @human, and enable the dev
# lane; `ModelInvocations::ApplyResultTest` is the original tenant.
module InvocationHarness
  class FakeAdapter < SimpleInference::HTTPAdapter
    attr_reader :requests

    def initialize(behaviour)
      @behaviour = behaviour
      @requests = []
    end

    def call(request)
      @requests << request
      raise @behaviour if @behaviour.is_a?(Exception)

      @behaviour
    end

    # ONLY AN EVENT-STREAM STREAMS. The real adapter nils the body for a
    # text/event-stream response and returns every other one WHOLE — and
    # this faked that by nilling unconditionally, so a non-2xx JSON body
    # never survived the trip. Every failure test in the repo could
    # therefore assert on the status and nothing else, and any code that
    # reads a provider's error body was untestable through the harness
    # that exists to drive the real chain.
    def call_stream(request, &block)
      @requests << request
      raise @behaviour if @behaviour.is_a?(Exception)
      return @behaviour unless block_given?
      return @behaviour unless event_stream?

      Array(@behaviour[:sse]).each { |frame| yield frame }
      @behaviour.except(:sse).merge(body: nil)
    end

    private

      def event_stream?
        @behaviour.is_a?(Hash) &&
          @behaviour.dig(:headers, "content-type").to_s.include?("text/event-stream")
      end
  end

  private

    # A bounded spin for reactor-driven tests: yields the fiber until the
    # condition holds, and fails the test instead of hanging the run.
    def spin_until(what, timeout: 5)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until yield
        flunk "timed out waiting for #{what}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep(0.01)
      end
    end

    def apply_via(attempt, behaviour)
      built = build(attempt)
      raise "build refused: #{built.refusal.inspect}" unless built.built?
      started = start(attempt)

      fake_dispatch(behaviour) do
        sent = ModelInvocations::Dispatch.call(
          attempt: started.attempt, context: started.context, request: built.request
        )
        return ModelInvocations::ApplyResult.call(attempt: started.attempt, outcome: sent)
      end
    end

    def fake_dispatch(behaviour, &block)
      fake = FakeAdapter.new(behaviour)
      ModelInvocations::ExecutionAdapter.stub(:for, ->(*) { fake }) { block.call(fake) }
    end

    def start(attempt)
      invocation = attempt.model_invocation
      profile = DevModelLane.profile_for_invocation(invocation)
      base_url = ModelCatalog.provider_base_url(invocation.provider_id)
      result = ModelInvocations::ProviderStart.call(
        attempt: attempt, host: "solid_queue", base_url: base_url, profile: profile
      )
      raise "start refused: #{result.outcome.inspect}" unless result.started?

      result
    end

    def build(attempt)
      invocation = attempt.model_invocation
      ModelRequests::Build.call(
        invocation: invocation, profile: DevModelLane.profile_for_invocation(invocation),
        base_url: ModelCatalog.provider_base_url(invocation.provider_id), host: "solid_queue"
      )
    end

    # A stream that stops early: the terminal is `response.incomplete` and the
    # cutoff cause rides where the wire puts it, in incomplete_details.reason.
    # `tool_calls:` renders the same function_call output items
    # `sse_success` builds — a cut stream can carry calls whose arguments
    # the budget cut mid-string.
    def sse_incomplete(text, reason: "max_output_tokens", tool_calls: [],
                       usage: { "input_tokens" => 2, "output_tokens" => 3 })
      terminal = {
        "type" => "response.incomplete",
        "response" => {
          "id" => "resp_1", "status" => "incomplete",
          "incomplete_details" => { "reason" => reason },
          "output" => [
            *function_call_items(tool_calls),
            { "type" => "message", "role" => "assistant",
              "content" => [{ "type" => "output_text", "text" => text }] },
          ],
          "usage" => usage,
        },
      }
      { sse: [
          %(data: {"type":"response.output_text.delta","delta":#{text.to_json}}\n\n),
          "data: #{JSON.generate(terminal)}\n\n",
          "data: [DONE]\n\n",
        ],
        status: 200, headers: { "content-type" => "text/event-stream", "x-request-id" => "req_1" } }
    end

    # The output in a live round's order — the reasoning, the message it
    # produced, then the calls (every probed GPT-6 round) — with the
    # message's `phase` when the wire labels it.
    def sse_success(text, reasoning: nil, reasoning_encrypted: nil, tool_calls: [], phase: nil,
                    usage: { "input_tokens" => 2, "output_tokens" => 3 })
      frames = []
      if reasoning
        frames << %(data: {"type":"response.reasoning_text.delta","delta":#{reasoning.to_json},"item_id":"r1"}\n\n)
      end
      frames << %(data: {"type":"response.output_text.delta","delta":#{"Mock: #{text}".to_json}}\n\n)
      output = [
        *(reasoning ? [{ "type" => "reasoning", "id" => "r1",
                         "summary" => [{ "type" => "summary_text", "text" => reasoning }],
                         **(reasoning_encrypted ? { "encrypted_content" => reasoning_encrypted } : {}) }] : []),
        { "type" => "message", "role" => "assistant", **(phase ? { "phase" => phase } : {}),
          "content" => [{ "type" => "output_text", "text" => "Mock: #{text}" }] },
        *function_call_items(tool_calls),
      ]
      { sse: frames + responses_completed_frames(output, usage),
        status: 200, headers: { "content-type" => "text/event-stream", "x-request-id" => "req_1" } }
    end

    # A Responses refusal: the message's `refusal` part, under a response
    # whose status says only `completed`. `text` streams ahead of it — the
    # partial answer a classifier can cut after it went out. The wire names
    # no category.
    def sse_refused(explanation, text: nil, usage: { "input_tokens" => 2, "output_tokens" => 1 })
      content = [
        *(text ? [{ "type" => "output_text", "text" => text }] : []),
        { "type" => "refusal", "refusal" => explanation },
      ]
      deltas = text ? [%(data: {"type":"response.output_text.delta","delta":#{text.to_json}}\n\n)] : []
      { sse: deltas + responses_completed_frames([{ "type" => "message", "role" => "assistant", "content" => content }], usage),
        status: 200, headers: { "content-type" => "text/event-stream", "x-request-id" => "req_1" } }
    end

    # A completed round over an arbitrary output list — the multi-item
    # rounds (thinking between calls, a preamble and a final answer) no
    # `sse_success` argument can spell. The streamed text is every
    # message's words, in order.
    def responses_output(items, usage: { "input_tokens" => 2, "output_tokens" => 3 })
      text = items.select { |item| item["type"] == "message" }
        .flat_map { |item| item["content"] }.filter_map { |part| part["text"] }.join
      deltas = text.empty? ? [] : [%(data: {"type":"response.output_text.delta","delta":#{text.to_json}}\n\n)]
      { sse: deltas + responses_completed_frames(items, usage),
        status: 200, headers: { "content-type" => "text/event-stream", "x-request-id" => "req_1" } }
    end

    def responses_completed_frames(output, usage)
      completed = {
        "type" => "response.completed",
        "response" => { "id" => "resp_1", "status" => "completed", "output" => output, "usage" => usage },
      }
      ["data: #{JSON.generate(completed)}\n\n", "data: [DONE]\n\n"]
    end

    # tool_calls: [{id:, name:, arguments:}] — rendered as Responses function_call output items, the
    # wire the dev lane speaks.
    def function_call_items(tool_calls)
      Array(tool_calls).map do |call|
        { "type" => "function_call", "id" => "item_#{call[:id]}",
          "call_id" => call[:id], "name" => call[:name],
          "arguments" => call[:arguments] || "{}" }
      end
    end

    def json_response(status, body, headers: {})
      { status: status,
        headers: { "content-type" => "application/json" }.merge(headers),
        body: JSON.generate(body) }
    end

    def png_bytes
      @png_bytes ||= Base64.decode64(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
      )
    end

    def wav_bytes = "RIFF\x00\x00\x00\x00WAVEfmt mock-audio".b

    def admitted_attempt(workload: "text_generation", model: nil, input: "say hi",
                         creator: nil, upload: nil, reasoning_effort: nil)
      selection = DevModelLane.selection(
        workload: workload, account: @account, reasoning_effort: reasoning_effort, **(model ? { model: model } : {})
      )
      one_shot = OneShot.create!(
        account: @account, workspace: workspaces(:shared), creating_user: creator || @human,
        workload: selection.workload
      )
      uploads =
        if upload
          bytes = upload.fetch(:bytes)
          record = @account.content_uploads.create!(
            creating_user: creator || @human,
            file: ActiveStorage::Blob.create_and_upload!(
              io: StringIO.new(bytes), filename: "clip#{SecureRandom.hex(2)}",
              content_type: upload.fetch(:media_type)
            )
          )
          [record]
        else
          []
        end
      body = ContentBodies::Replace.call(
        owner: one_shot, role: OneShots::Create::BODY_ROLE,
        entries: Nexus::InputEntries.for(input), uploads: uploads, seal: true
      )
      raise "input refused: #{body.refusal.inspect}" unless body.accepted?

      invocation = DevModelLane.create_invocation!(one_shot: one_shot, selection: selection)
      ContentBodies::CloneSealed.call(source: body.body, owner: invocation, role: "request")
      admitted = ModelInvocations::AdmitQueuedWork.call.admitted
        .find { _1.invocation.id == invocation.id }
      raise "admission did not admit the fixture invocation" if admitted.nil?

      clear_enqueued_jobs
      admitted.attempt
    end
end
