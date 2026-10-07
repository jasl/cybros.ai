require "fileutils"
require "time"
require_relative "manual_openrouter_smoke"
require_relative "tool_discovery_smoke"
require_relative "runner_affinity_fixture"
require_relative "../../nexus/lib/nexus/model_ref"
require_relative "../../nexus/lib/nexus/model_tool_calls"
require_relative "../../nexus/lib/nexus/provider_definition"
require_relative "../../nexus/app/services/model_catalog"
require_relative "../../nexus/app/services/model_catalog/catalog_validation"
require_relative "../../nexus/app/services/model_catalog/model_definition"
require_relative "../../nexus/app/services/model_catalog/profile_builder"
require_relative "../../nexus/app/services/usage_records/pricing"

module E2E
  # A small paid prototype diagnostic, not product E2E: real model choices over
  # fictional Runner metadata and shell results, with one sample per cell.
  class RunnerAffinitySmoke
    MODELS = (ToolDiscoverySmoke.models + %w[gemini/gemini-3.8-flash xai/grok-4.7]).freeze
    CASES = [["runners", "clear"], ["environments", "clear"],
      ["runners", "already_current"], ["runners", "ambiguous"]].freeze
    OUTPUT_TOKENS = 4096
    REQUEST_SECONDS = 120
    COST_STOP_USD = BigDecimal("3")
    UNKNOWN_RESERVE_USD = BigDecimal("0.10")
    Fixture = RunnerAffinityFixture

    def initialize(env: ENV, output: $stdout)
      @env = env
      @output = output
      @models = env.fetch("E2E_RUNNER_AFFINITY_MODELS", MODELS.join(",")).to_s.split(",").map(&:strip).reject(&:empty?).uniq
      if @models.empty? || (@models - MODELS).any?
        raise ArgumentError, "E2E_RUNNER_AFFINITY_MODELS must name models from this diagnostic's roster (comma-separated)"
      end
      @records = []
      @ids = Array.new(3) { SecureRandom.uuid_v7 }
      @blocked = {}
    end

    def preflight
      @models.map do |model|
        client, route, = client_for(model, offline: true)
        bodies = CASES.map do |vocabulary, _scenario|
          request = client.responses.compile(model: route.model, stream: true,
            **request_options(model, vocabulary, first_input))
          JSON.parse(request.payload)
        end
        { "model" => model, "endpoint" => route.lane.base_url, "api_format" => route.lane.format,
          "compiled_cases" => bodies.length, "reasoning" => reasoning(model),
          "synthetic_cost_check" => cost(model, { "input_tokens" => 1000, "output_tokens" => 32,
            "prompt_tokens" => 1000, "completion_tokens" => 32 }, route.lane.format) }
      end
    end

    def run
      ManualClient.validate!(@env, key_names: ProviderLanes.provider_keys_for(@models).values)
      preflight
      directory = File.expand_path("../artifacts/runner-affinity-smoke", __dir__)
      FileUtils.mkdir_p(directory, mode: 0o700)
      @path = File.join(directory, "#{Time.now.utc.strftime("%Y%m%dT%H%M%S")}-#{Process.pid}.json")
      @models.each do |model|
        CASES.each do |vocabulary, scenario|
          record = { "model" => model, "vocabulary" => vocabulary, "scenario" => scenario,
                     "cell" => [model, vocabulary, scenario].join(":"), "requests" => [] }
          @records << record
          if @blocked[model]
            record["skipped"] = @blocked.fetch(model)
          elsif budget_spent >= COST_STOP_USD
            record["skipped"] = "campaign_cost_stop"
          else
            draw(record)
          end
          save
          @output.puts "#{record.fetch("cell")}: #{record["skipped"] ? "SKIP" : (record.dig("grade", "pass") ? "PASS" : "FAIL")} " \
            "requests=#{record.fetch("requests").length} known_usd=#{known_cost.to_s("F")} " \
            "unknown_reserve_usd=#{unknown_reserve.to_s("F")}"
          @output.flush
        end
      end
      report.slice("artifact", "known_cost_usd", "unknown_cost_reserve_usd", "summary")
    end

    private

      def draw(record)
        model = record.fetch("model")
        vocabulary = record.fetch("vocabulary")
        fixture = Fixture.new(vocabulary: vocabulary, scenario: record.fetch("scenario"), ids: @ids)
        record.merge!("fixture_rows" => fixture.rows, "tools" => Fixture.tools(vocabulary),
          "user_request" => Fixture::USER_REQUEST, "instructions" => Fixture::INSTRUCTIONS,
          "started_at" => Time.now.utc.iso8601)
        client, route, capture = client_for(model)
        record.merge!("endpoint" => route.lane.base_url, "api_format" => route.lane.format,
          "wire_model" => route.model, "reasoning" => reasoning(model))
        input = first_input
        reply = nil
        max_requests = record.fetch("scenario") == "ambiguous" ? 8 : 6
        max_requests.times do |index|
          if budget_spent >= COST_STOP_USD
            record["stopped"] = "campaign_cost_stop"
            break
          end
          request = { "index" => index + 1, "input" => input }
          record.fetch("requests") << request
          result = ask(client, route, capture, model, vocabulary, input, request)
          save
          if result.nil?
            record["error"] = request["error"]
            block_common_configuration(record, request) if index.zero?
            break
          end
          calls = Nexus::ModelToolCalls.normalize(result.tool_calls)
          request["normalized_calls"] = calls
          if request["finish_quality"]
            record["stopped"] = "provider_finish_#{request.fetch("finish_quality")}"
            break
          end
          replay = replay(result, calls, route.lane.format)
          if calls.empty?
            reply = result.output_text
            if fixture.clarification_needed?(reply)
              user_text = fixture.clarify(reply)
              request["injected_user_clarification"] = user_text
              input = input + replay + [{ "role" => "user", "content" => user_text }]
              reply = nil
            else
              break
            end
          else
            outputs = fixture.apply(calls)
            request["mock_tool_results"] = outputs
            input = input + replay + outputs
            break if fixture.violations.any?
          end
        end
        record["stopped"] = "request_limit" if record.fetch("requests").length == max_requests && reply.nil?
        record.merge!("reply" => reply, "events" => fixture.events, "grade" => fixture.grade(reply),
          "finished_at" => Time.now.utc.iso8601)
        record.fetch("grade")["pass"] = false if record["error"] || record["stopped"]
      rescue StandardError => error
        record.merge!("harness_error" => ManualClient.error_text(error), "events" => fixture&.events,
          "grade" => { "pass" => false, "violations" => ["harness_error"] })
        # A harness fault is not a model result; preserve it and stop all later
        # draws instead of buying more calls under broken measurement code.
        @models.each { |ref| @blocked[ref] = "harness_error: #{error.class}" }
      end

      def client_for(model, offline: false)
        route = ProviderLanes.route(model)
        catalog = ProviderLanes.catalog
        profile = ModelCatalog::ProfileBuilder.call(model_ref: model,
          provider: catalog.fetch("providers").fetch(route.lane.provider_id),
          model: ModelCatalog::ModelDefinition.normalize(catalog.fetch("models").fetch(model), model_ref: model))
        capture = ManualOpenRouterSmoke::Capture.new(SimpleInference::HTTPAdapters::HTTPX.new)
        client = SimpleInference::Client.new(base_url: route.lane.base_url,
          api_key: offline ? "offline-placeholder" : @env.fetch(route.lane.key_name),
          timeout: REQUEST_SECONDS, adapter: capture, execution_profile: profile)
        [client, route, capture]
      end

      def first_input = [{ "role" => "user", "content" => Fixture::USER_REQUEST }]

      def reasoning(model)
        declared = ProviderLanes.catalog.fetch("models").fetch(model).fetch("capabilities").fetch("reasoning")
        { reasoning_effort: declared.fetch("default_effort"), reasoning_enabled: declared.fetch("default_enabled", true) }
      end

      def request_options(model, vocabulary, input)
        { instructions: Fixture::INSTRUCTIONS, input: input, tools: Fixture.tools(vocabulary), tool_choice: "auto",
          max_output_tokens: OUTPUT_TOKENS, **reasoning(model) }
      end

      def ask(client, route, capture, model, vocabulary, input, request)
        capture.reset
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = client.responses.stream(model: route.model, **request_options(model, vocabulary, input)).each { |_event| }
        request.merge!(ManualClient.facts(result, route.lane),
          "text" => result.output_text, "raw_tool_calls" => result.tool_calls,
          "output_items" => result.output_items, "assistant_message" => result.assistant_message,
          "raw_usage" => result.usage, "cost" => cost(model, result.usage, route.lane.format))
        result
      rescue SimpleInference::Error => error
        request["error"] = ManualClient.error_text(error)
        nil
      ensure
        request.merge!("seconds" => (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3),
          "provider_attempts" => capture.request_count, "http_status" => capture.status,
          "request_body" => capture.request_body, "response_body" => capture.response_body)
      end

      # Replay native material on the same lane/model, including every signed
      # call. The chat wire returns a message; the other wires return items.
      def replay(result, calls, format)
        if format == "openrouter_chat"
          message = result.assistant_message
          native_calls = Array(message["tool_calls"]).zip(calls).map { |call, normalized| call.merge("id" => normalized.fetch("id")) }
          return [message.merge("tool_calls" => native_calls)]
        end

        call_index = 0
        result.output_items.flat_map do |item|
          if item["type"] == "function_call"
            normalized = calls.fetch(call_index)
            call_index += 1
            [item.merge("call_id" => normalized.fetch("id"))]
          elsif %w[anthropic_messages gemini_generate_content].include?(format)
            [native_message(item, format)]
          else
            [item]
          end
        end
      end

      def native_message(item, format)
        parts = case item.fetch("type")
        when "message"
          item.fetch("content").map { |part| { "type" => "text", "text" => part.fetch("text") } }
        when "reasoning"
          if format == "anthropic_messages"
            [item["provider_payload"] || { "type" => "thinking", "thinking" => item.fetch("text"), "signature" => item.fetch("signature") }]
          else
            [{ "type" => "thought", "text" => item.fetch("text"), "thoughtSignature" => item["signature"] }.compact]
          end
        when "redacted_thinking"
          [{ "type" => "redacted_thinking", "data" => item.fetch("data") }]
        else
          raise "unhandled native replay item #{format}: #{item.fetch("type")}"
        end
        { "role" => "assistant", "content" => parts }
      end

      def cost(model, usage, format)
        catalog = ProviderLanes.catalog
        entry = catalog.fetch("models").fetch(model)
        provider = catalog.fetch("providers").fetch(ProviderLanes.provider_of(model))
        schedule = entry.fetch("pricing").fetch("schedule")
        rates = schedule.fetch("rates").transform_values { |value| BigDecimal(value) }
        multipliers = schedule.fetch("tier_multipliers", {}).transform_values { |value| BigDecimal(value) }
        contract = entry["native_cost_contract"] || provider["native_cost_contract"]
        contract = nil if schedule.fetch("kind") == "catalog_only"
        tokens = UsageRecords::Tokens.read(usage, adapter_profile: format)
        native = UsageRecords::Pricing.provider_reported(usage: usage, contract: contract, account_unit: "USD", adapter_profile: format)
        amount = UsageRecords::Pricing.amount(usage: usage, contract: contract, account_unit: "USD", adapter_profile: format,
          tokens: tokens, rates: rates, tier_multipliers: multipliers)
        source = if amount.nil?
          "unknown"
        elsif native.nil?
          "catalog_estimate"
        else
          "provider_reported"
        end
        { "amount_usd" => amount&.to_s("F"), "source" => source }
      end

      def block_common_configuration(record, request)
        status = request["http_status"].to_i
        body = request["response_body"].to_s
        blocked = [401, 403].include?(status) ||
          ([400, 404].include?(status) && body.match?(/schema|model.{0,100}(?:not found|does not exist|not available|invalid)|invalid.{0,40}model/i)) ||
          (status == 429 && body.match?(/insufficient.{0,30}(?:quota|credit|balance)/i))
        @blocked[record.fetch("model")] = "same_configuration_http_#{status}: #{request.fetch("error")}" if blocked
      end

      def requests = @records.flat_map { |record| record.fetch("requests") }

      def known_cost
        requests.filter_map { |request| request.dig("cost", "amount_usd") }.sum(BigDecimal("0")) { |amount| BigDecimal(amount) }
      end

      def unknown_reserve
        requests.count { |request| request.fetch("provider_attempts", 0).positive? && request.dig("cost", "amount_usd").nil? } * UNKNOWN_RESERVE_USD
      end

      def budget_spent = known_cost + unknown_reserve

      def report
        { "artifact" => @path, "models" => @models, "max_output_tokens" => OUTPUT_TOKENS,
          "request_timeout_seconds" => REQUEST_SECONDS, "max_requests" => { "ordinary" => 6, "ambiguous" => 8 },
          "cost_stop_usd" => COST_STOP_USD.to_s("F"), "known_cost_usd" => known_cost.to_s("F"),
          "unknown_cost_reserve_usd" => unknown_reserve.to_s("F"),
          "cost_note" => "Usage-priced estimates and provider-reported bills are distinguished per request. " \
            "Unknown amounts reserve USD 0.10 each, never a claim of zero cost; the stop is checked between requests.",
          "scope" => "One real-model sample per cell over fictional tools. No shell runs. " \
            "Names are fictional; description/hostname are proposed independent metadata fields. " \
            "Indices belong to this fixed list in one model context; changing/concurrent production lists are untested.",
          "grading_note" => "Automatic candidates only. A person must review every clarification question for machine disambiguation " \
            "and every bash command for status-inspection intent. This does not establish statistical reliability.",
          "summary" => { "passed" => @records.count { |record| record.dig("grade", "pass") },
            "failed" => @records.count { |record| record.dig("grade", "pass") == false },
            "skipped" => @records.count { |record| record["skipped"] }, "provider_attempts" => requests.sum { |request| request.fetch("provider_attempts", 0) } },
          "records" => @records }
      end

      def save
        return if @path.nil?

        text = JSON.pretty_generate(report)
        ProviderLanes::KEY_NAMES.each_value do |name|
          secret = @env[name].to_s
          text = text.gsub(secret, "[REDACTED]") unless secret.empty?
        end
        File.open("#{@path}.tmp", "w", 0o600) { |file| file.write("#{text}\n") }
        File.rename("#{@path}.tmp", @path)
      end
  end
end
