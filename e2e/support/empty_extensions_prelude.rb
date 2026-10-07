# Loaded through RUBYOPT into every rho process the executor-plane and expiry journeys spawn: the
# shipped default set shrinks to NO TOOL EXTENSION, so rho announces `[]` on the executor plane,
# serves no tool, and each journey NAMES the harness's `E2E::ExecutorProcess` on the create (the
# kernel infers no binding, r-modes M6). Ops stays: it registers verbs and routes only (`watch`,
# `attach`, `retry`, `abandon`) and announces nothing, and the expiry journey is a person's path
# through exactly those verbs against work the process holds.
#
# The empty Agent declaration still offers the echo tools' ordinary names so
# provider-pool journeys can call them without local handlers. Nexus separately
# imports the selected Runner's concrete routes and exact served schemas. This
# changes Agent declarations only; an empty Runner announcement still supplies
# no tools and never acquires the provider fixtures merely because it is empty.
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
  Rho::Extensions.send(:remove_const, :TOOL_GEMS)
  Rho::Extensions.const_set(:TOOL_GEMS, [].freeze)

  echo_registry = Rho::Runner::Extensions::Loader.call(builtin: [E2E::EchoTools]).registry
  echo_announcement = Rho::RunDeclaration.announcement(registry: echo_registry).freeze

  Rho::RunDeclaration.singleton_class.prepend(Module.new do
    define_method(:tool_entries) do |served|
      entries = super(served)
      next entries unless Rho::RunDeclaration.served_entries(served).empty?

      entries + super(echo_announcement)
    end
  end)
end
