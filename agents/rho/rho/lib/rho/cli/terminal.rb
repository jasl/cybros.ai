require_relative "../core"
require_relative "reporting"
require_relative "connect"
require_relative "turn_follow"
require_relative "run"
require_relative "browser"

module Rho
  # THE TERMINAL SURFACE: what `exe/rho` and every extension verb hold.
  # `Rho::Core` is the body (the primitives); `Cli` is the namespace of
  # what a terminal adds to it — the printer, the renderers and the
  # compositions the shipped verbs need (the ceremony's wait, the status
  # readout, `run`'s open-follow-print-exit). Nothing here reaches the
  # daemon but through a named core primitive
  # (`test/code_style/core_surface_test.rb`).
  module Cli
    # The object a verb handler receives (`Extensions::Api#register_command`:
    # `(cli, args, options)`): `core` for the daemon, `out` for the lines,
    # `home` for the one verb that writes the person's settings, and the
    # renderers mixed in.
    class Terminal
      include Reporting
      include Connect

      attr_reader :core, :out, :home

      # `out` is WRAPPED: every line rho prints — this
      # surface's and every extension verb's, since `cli.out` answers the
      # wrapper — goes through the one object that knows whether a model
      # delta left the cursor mid-line, which is what keeps `^run:` and
      # `^status:` anchored while text streams above them. A caller that
      # already holds one (a nested construction) is not wrapped twice.
      def initialize(home:, display_name: nil, out: $stdout, config: nil)
        @home = home
        @core = Rho::Core.new(home: home, display_name: display_name, config: config)
        @out = out.is_a?(Rho::StreamPrinter) ? out : Rho::StreamPrinter.new(out)
      end

      # The settings the daemon-less verbs read, the core's own.
      def config = core.config
    end
  end
end
