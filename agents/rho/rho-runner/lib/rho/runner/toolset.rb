module Rho
  # Reopened by `rho/runner.rb`, which holds the loop itself.
  class Runner
    # WHAT THIS RUNNER CAN DO — a frozen table from wire name to a handler.
    #
    # REGISTERED BY ANNOUNCEMENT: the daemon announces this
    # table's names on the executor plane, and nexus addresses a call to
    # this address only by what it announced. So there is no local "is this
    # mine?" gate before a claim — a row addressed here is one this address
    # announced — and the table's one job is to find the handler after a
    # claim. A name it no longer holds (an announcement drift under a
    # frozen addressee) is answered `failed` by the task run, never left
    # claimed.
    class Toolset
      # `validator` is the tool's `parameters` compiled ONCE, here, when the
      # toolset is assembled — every call is checked against it before the
      # handler runs (`InputSchema`), and compiling per call would be the
      # cost of a schema parse on every tool call the runner serves.
      # `timeout_ms` is the park the tool announced (nil for the kernel's
      # default); `internal_clamp` says the handler bounds itself (bash's
      # own timeout) and is never asked to extend its park.
      # `effect_profile` is the profile the tool ANNOUNCED (the class's
      # `EFFECT_PROFILE`, filled by the registry at `tool_for`): the
      # `tool_call`/`tool_result` hooks receive this value as their third
      # argument, so a hook that keys off "is this a write" reads
      # the profile as announced — an MCP tool's mapped annotations
      # included — never a name list of its own. nil on a tool built by
      # hand (a test's echo): no profile, no opinion.
      Tool = Data.define(:name, :description, :parameters, :handler, :validator, :timeout_ms, :internal_clamp,
        :effect_profile, :owner) do
        def initialize(name:, description:, parameters:, handler:, validator: nil, timeout_ms: nil,
                       internal_clamp: false, effect_profile: nil, owner: nil)
          super(name:, description:, parameters:, handler:,
            validator: validator || InputSchema.compile(parameters),
            timeout_ms:, internal_clamp:, effect_profile:, owner:)
        end

        # The MCP `Tool` shape, which is what a declaration looks like
        # everywhere this project touches one. `inputSchema` rather than
        # `parameters`: we rename what we own and never rename what MCP owns.
        def to_declaration
          { "name" => name, "description" => description, "inputSchema" => parameters }
        end
      end

      # `missing` is the answer for a name this table does not hold: the agent
      # slot's extended tables ask their `Toolsets` whether ANOTHER
      # conversation's editor serves the name and answer a refusing tool —
      # the model reads whose it is, as data — while nil falls through to
      # the `KeyError` the run reads as an announcement drift. Every other
      # table has none. POSITIONAL, because a braceless `Toolset.new("echo"
      # => tool)` binds a String-keyed literal as keywords the moment the
      # constructor accepts any.
      def initialize(tools = {}, missing = nil)
        @tools = tools.freeze
        @missing = missing
      end

      def fetch(tool_name)
        name = tool_name.to_s
        @tools.fetch(name) { @missing&.call(name) || raise(KeyError, "key not found: #{name.inspect}") }
      end

      def names = @tools.keys

      # The table itself, for the placement that extends it (`Toolsets#for`).
      def to_h = @tools

      def declarations = @tools.each_value.map(&:to_declaration)

      # THE SEVEN are assembled through the extension plane
      # (`Extensions::Coding`, registering exactly the way a third party's
      # gem does), and a runner takes its toolsets PER PLACEMENT
      # (`Toolsets`): the standalone answer — one placement, the coding set
      # over one env, no daemon composing it — is `Toolsets.fixed(env:)`.
    end
  end
end
