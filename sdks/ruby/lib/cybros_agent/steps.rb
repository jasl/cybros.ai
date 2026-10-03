module CybrosAgent
  # The step tree an author writes: values
  # with one `to_h` each — the whole codec — and one builder over them. Work
  # is placed in WRITTEN ORDER; `parallel` names a fan whose members run at
  # once; a barrier is the kernel's to place, never a step to write. Leaves
  # may add waits and select earlier results. The kernel holds the same values (`Step.from_h`),
  # two codecs of one wire shape, pinned as one by the contract pack.
  module Steps
    VERBS = %w[tool model ask wait script parallel].freeze

    # `detached: true` is the door's per-step word for a step the envelope
    # does not wait for — the node column's word; its answer reaches the
    # loop by the kernel's wake. `lifetime` independently selects whether
    # this reply must consume that result before final delivery; omission
    # inherits the enclosing work's selection.
    Tool = Data.define(:name, :input, :key, :timeout_ms, :detached, :lifetime, :wake,
      :on_failure, :visibility, :after) do
      def initialize(name:, input: {}, key: nil, timeout_ms: nil, detached: false, lifetime: nil, wake: nil,
                     on_failure: nil, visibility: nil, after: nil) = super

      def to_h = { "tool" => Steps.wire(super) }
    end

    # `prompt` is required on every public door; `model`, `tools`,
    # `instructions`, `configuration` and `compaction` name a surface of
    # its own where a continuation would inherit the round's.
    Model = Data.define(:prompt, :key, :model, :tools, :instructions, :configuration, :compaction,
      :fan_on_failure, :detached, :lifetime, :wake, :retries, :on_failure, :visibility, :after, :results) do
      def initialize(prompt:, key: nil, model: nil, tools: nil, instructions: nil, configuration: nil,
                     compaction: nil, fan_on_failure: nil, detached: false, lifetime: nil, wake: nil, retries: nil,
                     on_failure: nil, visibility: nil, after: nil, results: nil) = super

      def to_h = { "model" => Steps.wire(super) }
    end

    # `options`/`multi` are the question's choices as data: one string each, and whether several may be taken;
    # absent when the asker gives none.
    Ask = Data.define(:prompt, :options, :multi, :key, :timeout_ms, :detached, :lifetime, :wake, :on_failure, :visibility, :after) do
      def initialize(prompt:, options: nil, multi: nil, key: nil, timeout_ms: nil, detached: false, lifetime: nil, wake: nil,
                     on_failure: nil, visibility: nil, after: nil) = super

      def to_h = { "ask" => Steps.wire(super) }
    end

    # Observe work already launched without starting it again. The target
    # loop defaults to this execution; a hosted loop may name an earlier
    # execution in the same conversation. Timing out does not cancel it.
    Wait = Data.define(:task, :agent_loop, :key, :timeout_ms, :detached, :lifetime, :wake,
      :on_failure, :visibility, :after) do
      def initialize(task:, agent_loop: nil, key: nil, timeout_ms: nil, detached: false,
                     lifetime: nil, wake: nil, on_failure: nil, visibility: nil, after: nil) = super

      def to_h = { "wait" => Steps.wire(super) }
    end

    # Inputs are settled result envelopes in the declared order. The pure body
    # returns a JSON value or places a finite graph ending in one readable task.
    Script = Data.define(:script, :params, :model_defaults, :key, :detached, :lifetime, :wake,
      :on_failure, :visibility, :after, :results) do
      def initialize(script:, params: {}, model_defaults: nil, key: nil, detached: false, lifetime: nil, wake: nil,
                     on_failure: nil, visibility: nil, after: nil, results: nil) = super

      def to_h = { "script" => Steps.wire(super) }
    end

    # `members` holds steps and nested Arrays of steps (a sequence inside
    # the group); `until` — how many successes end the fan — is nil for the
    # default `all`, `"any"` or a quorum number for a race; `losers`/`key`/
    # `on_failure` belong to a race. `until` is a Ruby keyword: a label and
    # a member here, never a bare local, which is why `Sequence#parallel`
    # forwards its options whole.
    Parallel = Data.define(:members, :until, :losers, :key, :on_failure, :lifetime, :wake) do
      def initialize(members:, until: nil, losers: nil, key: nil, on_failure: nil, lifetime: nil, wake: nil) = super

      def to_h
        { "parallel" => members.map { |member| Steps.wire_tree(member) } }
          .merge(Steps.wire(super.except(:members)))
      end
    end

    class << self
      # One builder, one sequence frame; `parallel` opens a nested frame.
      def build
        sequence = Sequence.new
        yield sequence
        sequence.steps
      end

      # The envelope's `steps`: values render through their one codec, an
      # already-wire Hash passes through, a nested Array is a sequence.
      def envelope(steps)
        raise ArgumentError, "steps must be an Array" unless steps.is_a?(Array)

        steps.map { |step| wire_tree(step) }
      end

      # A value's members in the wire's spelling: `retries` is the wire's
      # `retry` (a keyword named `retry` cannot be read as a local), an
      # attached step carries no `detached`, absent stays absent.
      def wire(members)
        fields = members.to_h { |name, value| [name == :retries ? "retry" : name.to_s, value] }
        fields.delete("detached") unless fields["detached"]
        fields.compact
      end

      def wire_tree(member)
        case member
        when Array then member.map { |step| wire_tree(step) }
        when Hash then member
        else member.to_h
        end
      end
    end

    # A frame: every verb places one step at its end and answers it.
    class Sequence
      attr_reader :steps

      def initialize
        @steps = []
      end

      def tool(name, input: {}, **options) = push(Tool.new(name: name, input: input, **options))

      def model(prompt, **options) = push(Model.new(prompt: prompt, **options))

      def ask(prompt, **options) = push(Ask.new(prompt: prompt, **options))

      def wait(task:, **options) = push(Wait.new(task: task, **options))

      def script(source, **options) = push(Script.new(script: source, **options))

      def parallel(**options)
        group = Group.new
        yield group
        push(Parallel.new(members: group.steps, **options))
      end

      private

        def push(step)
          @steps << step
          step
        end
    end

    # A group's frame: a member is a step, or `sequence { … }` — steps that
    # run one after another inside the fan.
    class Group < Sequence
      def sequence
        nested = Sequence.new
        yield nested
        push(nested.steps)
      end
    end
  end
end
