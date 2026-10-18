require "json"
require "securerandom"
require_relative "manual_openrouter"
require_relative "red_square_png"

module E2E
  # A few bounded wire calls, independent of the shipped model roster and of a Nexus world.
  # Chat takes three requests (remember, call, consume); vision and a standalone tool take two.
  # Captures stay local. This is a provider diagnostic, not a product acceptance suite.
  class ManualOpenRouterSmoke
    TIMEOUT_SECONDS = 120
    MAX_OUTPUT_TOKENS = 4096
    TOOL = {
      type: "function", name: "lookup_marker", description: "Return the value belonging to a remembered marker.",
      parameters: { type: "object", properties: { marker: { type: "string" } },
                    required: ["marker"], additionalProperties: false },
    }.freeze

    # Observe only bodies, never credential-bearing request or response headers. A diagnostic
    # may explicitly pin one endpoint without changing the production protocol's provider block.
    # HTTPX owns transport and timeout handling; neither this wrapper nor the runner retries.
    class Capture < SimpleInference::HTTPAdapter
      attr_reader :request_body, :response_body, :status, :request_count

      def initialize(adapter, provider: "")
        @adapter = adapter
        @provider = provider
        reset
      end

      def reset
        @request_body = nil
        @response_body = +""
        @status = nil
        @request_count = 0
      end

      def call_stream(request)
        @request_count += 1
        @request_body = JSON.parse(request.fetch(:body))
        unless @provider.empty?
          @request_body.fetch("provider").merge!("only" => [@provider], "allow_fallbacks" => false)
          request = request.merge(body: JSON.generate(@request_body))
        end
        response = @adapter.call_stream(request) do |chunk|
          @response_body << chunk
          yield chunk
        end
        @status = response.fetch(:status)
        @response_body << response[:body].to_s
        response
      end

      # OpenRouter names the serving provider in its SSE JSON. Read it after the exchange;
      # a truncated final event remains in the raw capture but supplies no invented identity.
      def providers
        @response_body.split(/\r?\n\r?\n/).filter_map do |block|
          data = block.lines.filter_map { |line| line.delete_prefix("data:").strip if line.start_with?("data:") }.join("\n")
          next if data.empty? || data == "[DONE]"

          JSON.parse(data).fetch("provider", nil)
        rescue JSON::ParserError, TypeError, NoMethodError
          nil
        end.uniq
      end
    end

    def initialize(env: ENV, output: $stdout, adapter: nil)
      @env = env
      @output = output
      @adapter = adapter
      @rows = []
    end

    def run
      ManualOpenRouter.validate!(@env)
      chat_models = models("E2E_OPENROUTER_CHAT_MODELS")
      tool_models = models("E2E_OPENROUTER_TOOL_MODELS")
      vision_models = models("E2E_OPENROUTER_VISION_MODELS")
      reasoning_models = models("E2E_OPENROUTER_REASONING_MODELS")
      if chat_models.empty? && tool_models.empty? && vision_models.empty? && reasoning_models.empty?
        raise ArgumentError, "name E2E_OPENROUTER_CHAT_MODELS, E2E_OPENROUTER_TOOL_MODELS, E2E_OPENROUTER_VISION_MODELS or E2E_OPENROUTER_REASONING_MODELS (comma-separated OpenRouter ids)"
      end
      if reasoning_models.any? && @env["E2E_OPENROUTER_PROVIDER"].to_s.strip.empty?
        raise ArgumentError, "set E2E_OPENROUTER_PROVIDER for a reasoning comparison at the same endpoint"
      end

      chat_models.each { |model| chat(model) }
      tool_models.each { |model| tool(model) }
      vision_models.each { |model| vision(model) }
      reasoning_models.each { |model| reasoning(model) }
      summary = {
        "planned" => chat_models.length * 3 + (tool_models.length + vision_models.length + reasoning_models.length) * 2,
        "requests" => @rows.sum { |row| row.fetch("request_count") },
        "passed" => @rows.count { |row| row["pass"] == true },
        "failed" => @rows.count { |row| row["pass"] == false },
        "skipped" => @rows.count { |row| row.key?("skipped") },
      }
      write("summary" => summary)
      summary
    end

    private

      def models(name) = @env[name].to_s.split(",").map(&:strip).reject(&:empty?).uniq

      def chat(model)
        client, capture = client_for(model)
        marker = "marker-#{SecureRandom.hex(4)}"
        value = "value-#{SecureRandom.hex(4)}"
        input = [
          message("system", "You are a concise assistant. Retain the facts in this conversation."),
          message("developer", "When asked to remember a marker, reply with the single word READY and do not repeat the marker."),
          message("user", "Remember this marker: #{marker}."),
        ]
        first = request(client, capture, model, "chat_remember", input,
          expectation: "READY, without a tool call", reasoning: { enabled: true }) do |result|
          result.output_text.strip == "READY" && result.tool_calls.empty?
        end
        unless first
          skip(model, "chat_tool", "chat_remember failed")
          skip(model, "chat_result", "chat_remember failed")
          return
        end

        # The second developer message deliberately follows an actual assistant history item.
        # Replay the provider's entire assistant message, including native reasoning blocks.
        input += [first.assistant_message,
          message("developer", "Use lookup_marker with the marker remembered earlier. After its result arrives, reply with only its value."),
          message("user", "Look up the marker I gave you.")]
        second = request(client, capture, model, "chat_tool", input,
          expectation: "one lookup_marker call with marker #{marker}",
          tools: [TOOL], tool_choice: "auto", reasoning: { enabled: true }) do |result|
          expected_call?(result, marker)
        end
        unless second
          skip(model, "chat_result", "chat_tool did not return the expected single call")
          return
        end

        call = second.tool_calls.fetch(0)
        input += [second.assistant_message,
          { "role" => "tool", "tool_call_id" => call.fetch("id"), "content" => JSON.generate("value" => value) }]
        request(client, capture, model, "chat_result", input,
          expectation: "#{value}, without a tool call",
          tools: [TOOL], tool_choice: "none", reasoning: { enabled: true }) do |result|
          result.output_text.strip == value && result.tool_calls.empty?
        end
      end

      def tool(model)
        client, capture = client_for(model)
        marker = "marker-#{SecureRandom.hex(4)}"
        value = "value-#{SecureRandom.hex(4)}"
        input = [message("system", "Call lookup_marker when asked. After its result arrives, answer with only its value."),
          message("user", "Look up marker #{marker}.")]
        first = request(client, capture, model, "tool_call", input,
          expectation: "one lookup_marker call with marker #{marker}",
          tools: [TOOL], tool_choice: "auto", reasoning: { enabled: true }) do |result|
          expected_call?(result, marker)
        end
        unless first
          skip(model, "tool_result", "tool_call did not return the expected single call")
          return
        end

        input += [first.assistant_message,
          { "role" => "tool", "tool_call_id" => first.tool_calls.fetch(0).fetch("id"),
            "content" => JSON.generate("value" => value) }]
        request(client, capture, model, "tool_result", input,
          expectation: "#{value}, without a tool call",
          tools: [TOOL], tool_choice: "none", reasoning: { enabled: true }) do |result|
          result.output_text.strip == value && result.tool_calls.empty?
        end
      end

      def vision(model)
        client, capture = client_for(model)
        input = vision_input
        first = request(client, capture, model, "vision_colour", input,
          expectation: "one word: red", reasoning: { enabled: false }) do |result|
          result.output_text.strip.match?(/\Ared[.!]?\z/i)
        end
        unless first
          skip(model, "vision_history", "vision_colour failed")
          return
        end

        input += [first.assistant_message, message("user", "What shape was it? Answer with one word.")]
        request(client, capture, model, "vision_history", input,
          expectation: "one word: square or rectangle", reasoning: { enabled: false }) do |result|
          result.output_text.strip.match?(/\A(?:square|rectangle)[.!]?\z/i)
        end
      end

      def reasoning(model)
        client, capture = client_for(model)
        input = vision_input
        [false, true].each do |enabled|
          request(client, capture, model, enabled ? "reasoning_on" : "reasoning_off", input,
            expectation: "one word: red, with reasoning #{enabled ? "present" : "absent and zero reported reasoning tokens"}",
            reasoning: { enabled: enabled }, max_output_tokens: 1024) do |result|
            observed = reasoning_observation(result)
            thinking = observed.fetch("text_bytes").positive? || observed.fetch("detail_blocks").positive? || observed["tokens"].to_i.positive?
            result.output_text.strip.match?(/\Ared[.!]?\z/i) && (enabled ? thinking : !thinking && observed["tokens"] == 0)
          end
        end
      end

      def vision_input
        [message("system", "Answer the question about the picture with one word."),
          { "role" => "user", "content" => [
            { "type" => "input_text", "text" => "What colour is the shape in the middle of this picture?" },
            { "type" => "input_image", "image_url" => SimpleInference::MediaInput.from_bytes(RedSquarePng.bytes) },
          ] }]
      end

      def client_for(model)
        capture = Capture.new(@adapter || SimpleInference::HTTPAdapters::HTTPX.new,
          provider: @env["E2E_OPENROUTER_PROVIDER"].to_s.strip)
        client = ManualClient.client(lane: ManualOpenRouter.lane, model: model, env: @env,
          timeout: TIMEOUT_SECONDS, capabilities: ManualClient::CAPABILITIES + ["reasoning"], adapter: capture)
        [client, capture]
      end

      def message(role, text) = { "role" => role, "content" => text }

      def expected_call?(result, marker)
        calls = result.tool_calls
        return false unless calls.length == 1

        function = calls.fetch(0).fetch("function")
        function.fetch("name") == "lookup_marker" && JSON.parse(function.fetch("arguments")) == { "marker" => marker }
      rescue JSON::ParserError
        false
      end

      def request(client, capture, model, scenario, input, expectation:, max_output_tokens: MAX_OUTPUT_TOKENS, **options)
        capture.reset
        events = Hash.new(0)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        row = { "model" => model, "case" => scenario, "expectation" => expectation,
                "input_roles" => input.map { |item| item.fetch("role") },
                "timeout_seconds" => TIMEOUT_SECONDS, "max_output_tokens" => max_output_tokens }
        begin
          result = client.responses.stream(model: model, input: input, max_output_tokens: max_output_tokens, **options)
            .each { |event| events[event.type] += 1 }
          facts = ManualClient.facts(result, ManualOpenRouter.lane)
          row.merge!(facts)
          row["pass"] = facts["finish_quality"].nil? && yield(result)
          row["text"] = result.output_text
          row["tool_calls"] = result.tool_calls
          row["reasoning"] = reasoning_observation(result)
          result if row["pass"]
        rescue StandardError => error
          row.merge!("pass" => false, "error" => ManualClient.error_text(error))
          nil
        ensure
          row.merge!("seconds" => (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3),
            "request_count" => capture.request_count, "wire_roles" => Array(capture.request_body&.fetch("messages")).map { |item| item.fetch("role") },
            "providers" => capture.providers, "http_status" => capture.status, "events" => events,
            "request_body" => capture.request_body, "response_body" => capture.response_body)
          @rows << row
          write(row)
        end
      end

      def reasoning_observation(result)
        { "text_bytes" => result.assistant_message["reasoning_content"].to_s.bytesize,
          "detail_blocks" => Array(result.assistant_message["reasoning_details"]).length,
          "tokens" => result.usage.to_h.dig("completion_tokens_details", "reasoning_tokens") }.compact
      end

      def skip(model, scenario, reason)
        row = { "model" => model, "case" => scenario, "request_count" => 0, "skipped" => reason }
        @rows << row
        write(row)
      end

      def write(row)
        @output.puts(JSON.generate(row).gsub(@env.fetch("OPENROUTER_API_KEY"), "[REDACTED]"))
        @output.flush
      end
  end
end
