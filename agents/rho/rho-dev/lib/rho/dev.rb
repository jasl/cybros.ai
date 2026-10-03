require "rho"
require_relative "dev/version"
require_relative "dev/hints"
require_relative "dev/conversation"
require_relative "dev/watch"
require_relative "dev/follow"
require_relative "dev/loops"
require_relative "dev/inspect"
require_relative "dev/prompt"
require_relative "dev/relay"
require_relative "dev/conversations"
require_relative "dev/skills"
require_relative "dev/environment"

module Rho
  # THE DEVELOPMENT EXTENSION: the
  # verbs that operate a conversation from a terminal — open one and
  # return its ids (`do`), a second turn (`say`), the end (`stop`), a loop
  # watched, followed, read, repaired, decided, paused and deleted, the
  # bytes a round was sent, the prompt a send would seal, the rewind, the
  # regenerate, the skills, the access carrier — for the orchestrator,
  # e2e and other agents to test and debug through. A product install
  # carries the management verbs and `run`; this gem is what a developer's
  # home names (`{"extensions": ["rho/dev"]}`, its `lib` on the load path)
  # and the distribution never carries: not in rho's bundle, the
  # installer's manifest, the images or `rho doctor`.
  #
  # Every verb is a thin formatter over `Rho::Core`'s primitives through
  # the terminal it is handed (`cli.core.*`, `cli.out`, the shared
  # renderers), never a second client (`test/dev_cli_test.rb` greps the
  # transport out). The two COMPOSITIONS a terminal adds to the primitives
  # live here too: the poll (`watch`) and the pushed stream rendered
  # (`follow`) — the core holds no loop. The shared renderers name no
  # verb (`shipped_hints_test`); this gem's `Hints` name its own.
  module Dev
    NAME = "rho.dev".freeze

    # WHAT A WATCHER SHOWS, one knob per concern:
    # reasoning is always accumulated when the feed is open, and this
    # decides whether it is PRINTED — a two-place reasoning knob is the
    # shape where a person types a flag and sees nothing.
    STREAM_OPTIONS = {
      reasoning: { type: :boolean, default: false,
                   desc: "Also print the model's reasoning, dimmed, on its own channel" },
      stream: { type: :boolean, default: true,
                desc: "Print the reply as it is written (--no-stream leaves only the status lines)" },
    }.freeze

    # The forty, each under the module that formats it.
    def self.register(api)
      Conversation.register(api)
      Watch.register(api)
      Follow.register(api)
      Loops.register(api)
      Inspect.register(api)
      Prompt.register(api)
      Relay.register(api)
      Conversations.register(api)
      Skills.register(api)
      Environment.register(api)
    end

    # THE TERMINAL WITH THIS GEM'S RENDERERS: the shared `Rho::Cli::Terminal`
    # a verb is handed, with the hint hooks the shipped renderers leave
    # verb-free answered by `Hints` — so the ASKING line's park prints
    # `rho approve … | rho deny …`, an uncertain call `rho retry` or
    # `rho abandon`. One object, extended once.
    def self.terminal(cli)
      cli.singleton_class.include?(Hints) ? cli : cli.extend(Hints)
    end
  end
end
