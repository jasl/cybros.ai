require_relative "echo_tools"

module E2E
  # Independent delegates exercise the ordinary executor protocol. They need
  # no Rho application or member credential to summarize their supplied input.
  module CompactionTools
    class CompactHistory
      NAME = "compact_history".freeze
      DESCRIPTION = "Summarize the supplied history as references.".freeze
      SCHEMA = { "type" => "object", "properties" => {
        "history" => { "type" => "string" }, "retained_tail" => { "type" => "string" },
      } }.freeze
      EFFECT_PROFILE = EchoTools::READ_ONLY
      TIMEOUT_MS = 5_000

      def initialize(env:); end

      def call(args)
        Rho::Runner::Result.ok(["Independent summary", args.fetch("history"), args.fetch("retained_tail")].join("\n"))
      end
    end

    class HeldCompaction
      NAME = "held_compaction".freeze
      DESCRIPTION = CompactHistory::DESCRIPTION
      SCHEMA = CompactHistory::SCHEMA
      EFFECT_PROFILE = EchoTools::READ_ONLY
      TIMEOUT_MS = 5_000

      def initialize(env:); end

      def call(_args)
        loop do
          Rho::Runner::ExecutionContext.current&.raise_if_cancelled!
          sleep 0.05
        end
      end
    end

    TOOLS = [CompactHistory, HeldCompaction].freeze

    def self.names = TOOLS.map { |tool| tool::NAME }

    def self.register(api)
      TOOLS.each { |tool| api.register_tool(tool, serves: :runner) }
    end
  end
end
