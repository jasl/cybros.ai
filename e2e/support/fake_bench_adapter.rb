require "json"
require "simple_inference"
require_relative "provider_lanes"

module E2E
  # THE FAKE PROVIDER OF A SCREEN'S REHEARSAL: the gem's transport seam under a real
  # `ManualClient.for` client, so a fake job builds, sends and parses the lane's own wire and only
  # the socket is missing. It answers each request with a tracked canned body for the endpoint the
  # request hit (`fixtures/screen/fake/wire/<family>.json`) carrying the call the asking bench
  # wants: `compose` when the request declares the compose bench's own `read_file`; otherwise the
  # task probe's two steps (it declares rho's set, where reading is `read`) — a read (`ls`) while
  # the request carries no tool's answer yet, then a `task` call once one came back, or the canned
  # `compose` call when the ask is the claims objective's (`COMPOSE_DOOR`), so a rehearsal's claims
  # draw reaches the compose path of the task bench's `Door.kind`. A family that caches by marker
  # (Anthropic's) answers every call after the first with its `cached_usage`, the prefix read from
  # the cache the first call wrote — what the smoke's cache gate checks.
  #
  # `inject` — what the rehearsal makes go wrong, counted in calls answered:
  #   storm  every call from the third on meets a 503 on every attempt, so the client's retries
  #          are spent and it ends unreached (the STORM stop; a call answered on a retry is none)
  #   stall  the adapter sleeps `stall_seconds` before the fifth call (the STALL clock)
  #   fault  the second call raises NoMethodError — a harness-fault class (the job exits non-zero)
  #   spend  every body's usage is the family's two million output tokens (the SPEND stop)
  #   blind  read by `BenchRecords`: the job appends no record (the BLIND stop)
  class FakeBenchAdapter < SimpleInference::HTTPAdapter
    INJECTIONS = %w[storm stall fault spend blind].freeze
    WIRE = File.expand_path("fixtures/screen/fake/wire", __dir__)
    # The endpoint a request hits names the canned family that answers it.
    FAMILIES = { "/chat/completions" => "chat", "/messages" => "messages", "/responses" => "responses" }.freeze
    # How each family's request carries a tool's answer back to the model.
    ANSWERED = { "chat" => '"role":"tool"', "messages" => '"tool_result"', "responses" => '"function_call_output"' }.freeze
    # The claims objective's opening words: its ask is answered, after the look, with a compose door.
    COMPOSE_DOOR = "Six claims about".freeze
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
        if body.include?("\"read_file\"") then "compose"
        elsif body.include?(ANSWERED.fetch(name)) then body.include?(COMPOSE_DOOR) ? "compose" : "task"
        else "task_read"
        end
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
