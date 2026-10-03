require_relative "echo_tools"

module E2E
  # THE GUARDED ECHO (the `executor_relay` journey): a `bash` the harness RUNNER announces so a
  # relayed command reaches the kernel's approval stage at all — addressing runs first, and a name
  # nobody serves fails `tool_not_served` before any rule is read. The handler is the plain echo;
  # the point is the NAME and the open-world write profile, which rho's deny rules address
  # (`GUARDED_TOOLS`). Kept OUT of `EchoTools::TOOLS` on purpose: that list is the default a process
  # announces AND what the empty-extensions prelude declares as rho's own, and a `bash` in either
  # would collide with rho's real one in every journey that loads the prelude. A process names it
  # with `--tools`.
  module GuardedTools
    class Bash < EchoTools::Echo
      NAME = "bash".freeze
      DESCRIPTION = "Echoes a command (E2E harness executor; an open-world write).".freeze
      SCHEMA = {
        "type" => "object",
        "properties" => { "command" => { "type" => "string", "description" => "A command" } },
        "additionalProperties" => true,
      }.freeze
      EFFECT_PROFILE = EchoTools::WRITE
      TIMEOUT_MS = EchoTools::TIMEOUT_MS
    end

    TOOLS = [Bash].freeze

    class << self
      def names = TOOLS.map { |klass| klass::NAME }

      def register(api)
        TOOLS.each { |klass| api.register_tool(klass, serves: :runner) }
      end
    end
  end
end
