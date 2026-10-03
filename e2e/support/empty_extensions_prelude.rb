# Loaded through RUBYOPT into every rho process the executor-plane and expiry journeys spawn: the
# shipped default set shrinks to NO TOOL EXTENSION, so rho announces `[]` on the executor plane,
# serves no tool, and each journey NAMES the harness's `E2E::ExecutorProcess` on the create (the
# kernel infers no binding, r-modes M6). Ops stays: it registers verbs and routes only (`watch`,
# `attach`, `retry`, `abandon`) and announces nothing, and the expiry journey is a person's path
# through exactly those verbs against work the process holds.
#
# THE DECLARATION STILL CARRIES THE ECHO TOOLS' NAMES, AS THIS RHO'S OWN. A round admits only the
# tool names its declaration carried (nexus's `ExpandRound` fails any other as `unknown_tool`), and
# each turn is narrowed to the kernel's names ∪ this rho's OWN ∪ its bound runner's — so a
# pool-served name like the provider's `find` (E9), which no bound runner announces, reaches a turn
# only as one of rho's own. The profile's declaration is the operator's fact about what the model
# may call, and this prelude states it the way an operator whose tools run on other machines would:
# the echo tools' announcement entries — the one served shape, rendered by the registry's ONE
# renderer over a registry holding the echo module alone — stand in for the EMPTY list this rho's
# own registry announces (its runner address and its agent address alike), so they are this rho's
# own entries to every reader: the declaration, the turn's narrowing, the collision check. A runner
# elsewhere announcing the same tools renders the same bytes through the same renderer, so the union
# declares each name once. Rho holds no handler for any of them.
#
# No dispatch log: the executor-plane journey reads the process's log and
# the transcript, never rho's request lines.
begin
  require "rho"
rescue LoadError
  # The `bundle` launcher itself runs first, before bundler/setup put rho on
  # the load path; only the product process past it has anything to shrink.
else
  require_relative "executor_process/echo_tools"

  Rho::Extensions.send(:remove_const, :DEFAULT_EXTENSIONS)
  Rho::Extensions.const_set(:DEFAULT_EXTENSIONS, [Rho::Extensions::Ops].freeze)

  echo_registry = Rho::Runner::Extensions::Loader.call(builtin: [E2E::EchoTools]).registry
  echo_announcement = Rho::LoopRequest.announcement(registry: echo_registry).freeze

  Rho::LoopRequest.singleton_class.prepend(Module.new do
    define_method(:tool_entries) do |served|
      entries = super(served)
      next entries unless Rho::LoopRequest.served_entries(served).empty?

      entries + Rho::LoopRequest.tool_entries(echo_announcement)
    end
  end)
end
