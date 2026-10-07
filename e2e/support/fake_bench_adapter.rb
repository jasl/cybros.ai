require "json"
require "simple_inference"
require_relative "provider_lanes"

module E2E
  # Canned transport responses exercise the real client codecs without provider calls. The
  # first request reads the fixture; a request carrying that result delegates a task. Usage and
  # injected transport failures make accounting and retry checks reproducible.
  class FakeBenchAdapter < SimpleInference::HTTPAdapter
    INJECTIONS = %w[storm stall fault spend blind].freeze
    WIRE = File.expand_path("fixtures/bench_wire", __dir__)
    # The endpoint a request hits names the canned family that answers it.
    FAMILIES = { "/chat/completions" => "chat", "/messages" => "messages", "/responses" => "responses" }.freeze
    # How each family's request carries a tool's answer back to the model.
    ANSWERED = { "chat" => '"role":"tool"', "messages" => '"tool_result"', "responses" => '"function_call_output"' }.freeze
    STALL_SECONDS = 3600

    # Rehearsal models name wire behavior, independent of the paid catalog.
    FORMATS = { "fake/chat-a" => "openrouter_chat", "fake/chat-b" => "openrouter_chat",
                "fake/chat-control" => "openrouter_chat", "fake/responses" => "openai_responses",
                "fake/messages" => "anthropic_messages" }.freeze

    def self.route(ref)
      format = FORMATS.fetch(ref) { raise ArgumentError, "unknown fake model #{ref.inspect}" }
      lane = ProviderLanes::Lane.new(provider_id: "fake", format: format, base_url: "https://fake.invalid",
        key_name: "E2E_FAKE_API_KEY")
      ProviderLanes::Route.new(ref: ref, lane: lane, model: ref.delete_prefix("fake/"))
    end

    # Fixed local prices exercise spend accounting without loading a deployment catalog.
    def self.rates(root:, models:)
      models.to_h do |ref|
        [ref, { "adapter_profile" => route(ref).lane.format, "state" => "priced", "reason" => nil,
                "settles_money" => true, "account_unit" => "USD", "source_policy" => "catalog_only",
                "rates" => { "input_per_mtok" => "1", "output_per_mtok" => "2", "cache_read_per_mtok" => "0.1",
                             "cache_write_per_mtok" => "1.25", "cache_write_1h_per_mtok" => "2" },
                "tier_multipliers" => {}, "native_cost_contract" => nil }]
      end
    end

    # The comma list a job's `E2E_BENCH_FAKE_INJECT` holds, each word checked.
    def self.inject(env)
      words = env["E2E_BENCH_FAKE_INJECT"].to_s.split(",").map(&:strip).reject(&:empty?)
      unknown = words - INJECTIONS
      raise ArgumentError, "E2E_BENCH_FAKE_INJECT names #{unknown.join(", ")}; the fake knows #{INJECTIONS.join(", ")}" if unknown.any?

      words
    end

    def initialize(inject: [], stall_seconds: STALL_SECONDS, sleep: ->(seconds) { Kernel.sleep(seconds) })
      super()
      @inject = inject
      @stall_seconds = stall_seconds
      @sleep = sleep
      @answered = 0
      @stalled = false
    end

    # `@answered` counts calls answered, so a stormed call's retry is the same call.
    def call(request)
      ordinal = @answered + 1
      stall(ordinal)
      return answer(503, "error" => { "message" => "fake storm" }) if storm?(ordinal)

      @answered = ordinal
      raise NoMethodError, "undefined method 'fetch' for nil (fake fault)" if @inject.include?("fault") && ordinal == 2

      answer(200, body_for(request, ordinal))
    end

    private

      def stall(ordinal)
        return unless @inject.include?("stall") && ordinal == 5 && !@stalled

        @stalled = true
        @sleep.call(@stall_seconds)
      end

      def storm?(ordinal) = @inject.include?("storm") && ordinal >= 3

      def answer(status, body) = { status: status, headers: { "content-type" => "application/json" }, body: JSON.generate(body) }

      def body_for(request, ordinal)
        name = family_name(request.fetch(:url))
        canned = family(name)
        body = canned.fetch(kind(name, request.fetch(:body).to_s))
        if @inject.include?("spend") then body.merge("usage" => canned.fetch("spend_usage"))
        elsif ordinal > 1 && canned.key?("cached_usage") then body.merge("usage" => canned.fetch("cached_usage"))
        else body
        end
      end

      def kind(name, body)
        body.include?(ANSWERED.fetch(name)) ? "task" : "task_read"
      end

      def family_name(url)
        path = URI(url).path
        _suffix, name = FAMILIES.find { |suffix, _| path.end_with?(suffix) }
        raise ArgumentError, "the fake has no canned body for #{path}" unless name

        name
      end

      def family(name)
        (@families ||= {})[name] ||= JSON.parse(File.read(File.join(WIRE, "#{name}.json"), encoding: Encoding::UTF_8))
      end
  end
end
