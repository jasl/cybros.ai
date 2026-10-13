require "test_helper"
require "prism"

# A loop's event stream is only as complete as its narration, and narration
# beside every status write is a discipline that lasts exactly until the
# next transition is added. So the write and its event are ONE call —
# `AgentRuns::Transition` — and this guard is what keeps it that way: a
# status write anywhere else in the loop plane fails here rather than
# silently going dark on every follower.
class AgentRunNarrationTest < ActiveSupport::TestCase
  WRITERS = %i[update! update update_all update_columns].freeze
  # Both halves of a task's public settlement: the status AND the adjudication that resolves a
  # failure. The guard watched only the first and the abandon verb slipped straight through it.
  NARRATED_KEYS = %w[status failure_resolution].freeze
  SOURCES = (Rails.root.glob("app/services/agent_runs/**/*.rb") +
             Rails.root.glob("app/jobs/agent_runs/**/*.rb")).sort

  # The funnel itself, and the append door — whose newborn joins settle
  # mid-construction and are narrated as ONE batch afterwards, so each new
  # task appears exactly once already carrying its true status.
  EXEMPT = %w[
    app/services/agent_runs/transition.rb
    app/services/agent_runs/tasks/append.rb
  ].freeze

  class StatusWriteVisitor < Prism::Visitor
    attr_reader :violations

    def initialize(path)
      @path = path
      @violations = []
    end

    def visit_call_node(node)
      if WRITERS.include?(node.name) && narrated_keyword?(node)
        @violations << "#{@path}:#{node.location.start_line}: #{node.name}"
      end
      super
    end

    private

      def narrated_keyword?(node)
        arguments = node.arguments&.arguments || []
        arguments.any? do |argument|
          next false unless argument.instance_of?(Prism::KeywordHashNode)

          argument.elements.any? do |element|
            element.instance_of?(Prism::AssocNode) &&
              element.key.instance_of?(Prism::SymbolNode) &&
              NARRATED_KEYS.include?(element.key.unescaped)
          end
        end
      end
  end

  test "every loop and task status write goes through the one narrating funnel" do
    violations = SOURCES.flat_map do |path|
      relative = path.relative_path_from(Rails.root).to_s
      next [] if EXEMPT.include?(relative)

      visitor = StatusWriteVisitor.new(relative)
      Prism.parse(path.read).value.accept(visitor)
      visitor.violations
    end

    assert_empty violations,
      "these write a status without narrating it — route them through " \
      "AgentRuns::Transition.agent_run/node/nodes so the event stream cannot " \
      "silently lose a transition:\n  #{violations.join("\n  ")}"
  end

  test "the append door's exemption is paid for by its batch narration" do
    source = Rails.root.join("app/services/agent_runs/tasks/append.rb").read

    assert_includes source, "Transition.created",
      "append settles newborn joins directly, so it owes the batch narration " \
      "that makes each new task visible to a follower exactly once"
  end

  test "the closed item vocabulary is exactly what the writers emit" do
    # Only a file that RECORDS narration can emit an event item; `type:`
    # elsewhere in the plane names a different vocabulary entirely (the
    # composer's wire items — function_call, reasoning — are input shapes
    # bound for a provider, not events bound for a follower).
    emitted = (Rails.root.glob("app/services/agent_runs/**/*.rb") +
               Rails.root.glob("app/services/conversations/compaction/**/*.rb"))
      .map(&:read).select { |source| source.include?("Narration.record") }
      .flat_map { |source| source.scan(/type: "([a-z_]+)"/) }
      .flatten.uniq

    assert_equal [], emitted - ConversationEventItem::ITEM_TYPES,
      "a writer emits an item type the model would reject"
  end
end
