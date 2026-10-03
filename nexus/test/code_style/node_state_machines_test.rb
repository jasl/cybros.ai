require "test_helper"
require "prism"

# THE STATE MACHINES ARE COMPLETE, AS A PROPERTY RATHER THAN A CLAIM.
#
# Every task-node type exposes a complete state machine for consumers. Pin reachable states,
# terminal exits, stored vocabulary and actual transition writers: an unreachable state or a
# declared edge no writer takes misleads clients, while a nonterminal state with no exit can strand
# work.
class NodeStateMachinesTest < ActiveSupport::TestCase
  TYPES = [
    AgentLoopNodes::ModelTask, AgentLoopNodes::ToolTask, AgentLoopNodes::AwaitTask,
    AgentLoopNodes::JoinTask, AgentLoopNodes::DelegationTask, AgentLoopNodes::ScriptTask,
  ].freeze

  # The words a holder OUTSIDE the kernel rests a row in: an executor's
  # park and a person's question. A test-side pin, on purpose — the engine
  # reads them off each type's machine and the removal pass's own set,
  # never off a shared constant nothing in production consulted.
  HOLDER_WORDS = %w[dispatched awaiting_input].freeze

  # The roster itself: a subclass added without being listed here is a
  # machine nothing in this file checks.
  def test_every_node_type_is_covered_and_declares_its_own_machine
    assert_equal AgentLoopNode.descendants.map(&:name).sort, TYPES.map(&:name).sort,
      "a node type exists that this test does not check"
    TYPES.each { |type| assert_kind_of Hash, type.transitions, "#{type} declares no machine" }
    assert_nil AgentLoopNode.transitions, "the base declares no machine of its own"
  end

  def test_every_declared_state_is_a_word_the_column_knows
    TYPES.each do |type|
      unknown = type.statuses - AgentLoopNode::STATUSES
      assert_empty unknown, "#{type.task_kind} declares #{unknown.inspect}, which the column cannot hold"
    end
  end

  # The column's vocabulary is DECLARED, not computed from `descendants`
  # (which is empty under lazy loading). This is what keeps the two equal.
  def test_the_columns_vocabulary_is_exactly_the_union_of_the_types
    assert_equal AgentLoopNode::STATUSES.sort, TYPES.flat_map(&:statuses).uniq.sort
  end

  def test_every_state_is_reachable_from_birth
    TYPES.each do |type|
      reached = Set.new(type.transitions.fetch(nil, []))
      frontier = reached.to_a
      until frontier.empty?
        type.transitions.fetch(frontier.shift, []).each do |to|
          frontier << to if reached.add?(to)
        end
      end
      orphans = type.statuses - reached.to_a
      assert_empty orphans, "#{type.task_kind} can never reach #{orphans.inspect} from birth"
    end
  end

  # A task that cannot leave a non-terminal state is a task nothing can
  # ever finish — the hang this whole vocabulary exists to make visible.
  def test_every_non_terminal_state_has_an_exit
    TYPES.each do |type|
      (type.statuses - AgentLoopNode::TERMINAL_STATUSES).each do |status|
        assert_not_empty type.transitions.fetch(status, []),
          "#{type.task_kind} can enter #{status.inspect} and never leave it"
      end
    end
  end

  def test_no_terminal_state_claims_an_exit_except_the_adjudication_edges
    TYPES.each do |type|
      (type.statuses & AgentLoopNode::TERMINAL_STATUSES).each do |status|
        exits = type.transitions.fetch(status, [])
        next if exits.empty?

        assert_includes AgentLoopNode::FAILURE_STATUSES, status,
          "#{type.task_kind}: #{status} is terminal and must not lead anywhere"
        assert_equal %w[queued], exits,
          "#{type.task_kind}: the only exit from #{status} is adjudication putting it back"
      end
    end
  end

  # Approval belongs to tool calls, where effects execute. Model rounds use model admission and have
  # no approval stage; inspect the state-machine definition rather than duplicating a second state
  # list.
  def test_the_approval_stage_is_a_fact_about_the_machine_and_belongs_to_the_tool_call
    with_stage = TYPES.select(&:approval_stage?).map(&:task_kind)

    assert_equal %w[tool_task], with_stage,
      "the stage belongs to the one type whose effect reaches the person's machine"
    TYPES.each do |type|
      assert_equal type.statuses.include?("needs_approval"), type.approval_stage?
    end
    assert_not_includes AgentLoopNodes::ModelTask.statuses, "needs_approval"
  end

  # THE DEAD EDGES STAY DEAD (review 2026-09-08 change 2). `needs_approval →
  # skipped` was unreachable by construction — a row reaches the stage only
  # once every source settled, and settlements never regress; a join is
  # born `queued` and settles in the append door or the release walk, never
  # at birth. An edge nobody writes is a lie to every reader of the machine.
  def test_the_edges_the_review_found_dead_are_not_declared
    assert_equal %w[running dispatched failed timed_out canceled],
      AgentLoopNodes::ToolTask.transitions.fetch("needs_approval"),
      "the stage leaves forward (approve), by a denial, by the park clock, or by a cancel — never to skipped"
    assert_equal %w[queued], AgentLoopNodes::JoinTask.transitions.fetch(nil),
      "a join is born queued; its settlement is a transition the walk narrates"
  end

  # THE HELD SET: a row resting for an approver has spent nothing (pre-dispatch — a stop cancels
  # it), is never started (a drain never waits on it), and is on the park clock with the started
  # parks (the sweep's set is exactly their union).
  def test_every_held_status_is_pre_dispatch_and_on_the_park_clock
    assert_equal %w[needs_approval], AgentLoopNode::HELD_STATUSES
    assert_empty AgentLoopNode::HELD_STATUSES - AgentLoopNode::PRE_DISPATCH_STATUSES, "held ⊆ pre-dispatch"
    assert_empty AgentLoopNode::HELD_STATUSES & AgentLoopNode::STARTED_STATUSES, "held ∩ started = ∅"
    assert_equal AgentLoopNode::STARTED_STATUSES + AgentLoopNode::HELD_STATUSES, AgentLoopNode::SWEPT_STATUSES
    AgentLoopNode::HELD_STATUSES.each do |status|
      assert_predicate AgentLoopNodes::ToolTask.new(status: status), :held?
      assert_not AgentLoopNodes::ToolTask.new(status: status).started?
    end
  end

  # EVERY DECLARED TARGET HAS A WRITER. A Prism scan of every `status:
  # "<word>"` literal handed to a write in the loop plane (the funnel, the
  # addressing decision it applies, the append door's births) — reads
  # (`where`, `find_by`) are excluded — must cover every word the machines
  # promise to reach. A word declared here with no writer anywhere is the
  # next `needs_approval → skipped`. The `from` side is not derivable
  # statically (a writer's precondition is a guard, not a literal), so the
  # per-edge half is the review's job and this test keeps the target half.
  WRITER_SOURCES = (
    Rails.root.glob("app/services/agent_loops/**/*.rb") +
    Rails.root.glob("app/services/executors/**/*.rb") +
    Rails.root.glob("app/services/conversations/compaction/**/*.rb") +
    Rails.root.glob("app/models/**/*.rb")
  ).sort
  READERS = %i[where find_by find_by! exists? not rewhere pluck select reject include? fetch].freeze

  class StatusLiteralVisitor < Prism::Visitor
    attr_reader :words

    def initialize
      @words = Set.new
      @calls = []
    end

    def visit_call_node(node)
      @calls.push(node.name)
      super
    ensure
      @calls.pop
    end

    def visit_assoc_node(node)
      if status_key?(node.key) && node.value.instance_of?(Prism::StringNode) && !READERS.include?(@calls.last)
        @words << node.value.unescaped
      end
      super
    end

    private

      def status_key?(key)
        (key.instance_of?(Prism::SymbolNode) || key.instance_of?(Prism::StringNode)) &&
          key.unescaped == "status"
      end
  end

  def test_every_declared_target_word_has_a_writer
    visitor = StatusLiteralVisitor.new
    WRITER_SOURCES.each { |path| Prism.parse(path.read).value.accept(visitor) }
    # The column default is the birth writer for every queued row.
    written = visitor.words + [AgentLoopNode.column_defaults.fetch("status")]

    TYPES.each do |type|
      unwritten = type.transitions.values.flatten.uniq - written.to_a
      assert_empty unwritten,
        "#{type.task_kind} declares #{unwritten.inspect} as a target, and nothing in the loop plane writes it"
    end
  end

  # BEHAVIOUR BELONGS ON THE TYPE (owner 2026-09-04): a service asks the
  # node `round?`, `asking?`, `holds_invocation?`, `park_kind` — never
  # switches on its class. The `is_a?` guard already refuses the probe;
  # this refuses its `case` spelling, which six sites had grown.
  SERVICE_SOURCES = Rails.root.glob("app/services/**/*.rb").sort

  def test_no_service_switches_on_a_node_type
    violations = SERVICE_SOURCES.flat_map do |path|
      path.each_line.with_index(1).filter_map do |line, number|
        "#{path.relative_path_from(Rails.root)}:#{number}: #{line.strip}" if line.match?(/\bwhen AgentLoopNodes::/)
      end
    end

    assert_empty violations,
      "ask the node a polymorphic predicate instead of switching on its class:\n  #{violations.join("\n  ")}"
  end

  # WAITING IS NOT THE SAME AS BEING ON A CLOCK, and the two are easy to conflate because both are
  # called a park. A holder word is a status a row WAITS in for somebody outside the kernel; the
  # `Parked` concern is the CLOCKED park — one derived deadline, one sweep, one hold-ceiling rule.
  # Every such wait has a clock: the one that waited on a person for free — the idle window — died
  # with the conversation host, and nothing may take its place quietly. `clocked?` is the type's own
  # answer.
  def test_a_holder_word_is_always_on_a_clocked_type
    TYPES.each do |type|
      next if (type.statuses & HOLDER_WORDS).empty?

      assert type.include?(AgentLoopNodes::Parked),
        "#{type.task_kind} hands work out to a holder and must be swept for a deadline"
      assert_predicate type.new, :clocked?
    end
  end

  def test_a_clocked_type_declares_a_started_state_and_names_its_park
    TYPES.each do |type|
      next unless type.include?(AgentLoopNodes::Parked)

      # Pure scripts run in a kernel job; unlike an external holder they use
      # running, while the same park clock still bounds a lost worker.
      assert_not_empty type.statuses & AgentLoopNode::STARTED_STATUSES,
        "#{type.task_kind} is a clocked park with no started state"
      assert_kind_of String, type::PARK_KIND, "#{type.task_kind} names its park for the settle's error keys"
      assert_equal type::PARK_KIND, type.new.park_kind
    end
  end

  def test_an_unclocked_type_answers_neither
    (TYPES - TYPES.select { |type| type.include?(AgentLoopNodes::Parked) }).each do |type|
      assert_not type.new.clocked?, "#{type.task_kind} has no park clock"
      assert_nil type.new.park_kind
    end
  end
end
