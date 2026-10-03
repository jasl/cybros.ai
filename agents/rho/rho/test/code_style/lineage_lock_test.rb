require "test_helper"
require "prism"

# THE LOCK RANKING IS STRUCTURAL, NOT A DENYLIST. Lineage is the only non-leaf lock in the core, so what runs under
# its monitor is an allowlist: the object's own state, its own value types,
# literals, pure operators — nothing that can do IO, sleep, join or yield to
# a handler. The guard parses the file rather than trusting a comment.
class LineageLockTest < Minitest::Test
  LINEAGE = File.expand_path("../../lib/rho/daemon/lineage.rb", __dir__)
  # The helper modules the class includes hold
  # sections of the same monitor, so the guard reads them as one body.
  LINEAGE_HELPERS = Dir.glob(File.expand_path("../../lib/rho/daemon/lineage/*.rb", __dir__)).sort
  DAEMON_TREE = File.expand_path("../../lib/rho/daemon", __dir__)

  class Guard
    PURE = %i[== != < <= > >= + - * ! equal? nil? zero? positive? negative? empty?].freeze
    LITERALS = [
      Prism::ArrayNode, Prism::HashNode, Prism::StringNode, Prism::SymbolNode, Prism::IntegerNode,
      Prism::FloatNode, Prism::NilNode, Prism::TrueNode, Prism::FalseNode, Prism::RangeNode,
    ].freeze
    # The one section allowed to start a thread and to flip its argument's
    # phase: `pending` and its poller become visible together.
    PARAMETER_SECTIONS = %w[publish_pending].freeze

    Violation = Data.define(:method_name, :line, :text)

    def initialize(*sources)
      @programs = sources.map { |source| Prism.parse(source).value }
      @constants = []
      @verbs = []
      @violations = []
      @programs.each { |program| index_class_body(program) }
    end

    attr_reader :verbs, :constants

    def violations
      @programs.each do |program|
        each_def(program) do |definition|
          sections(definition).each { |section| check(section, definition) }
        end
      end
      @violations
    end

    private

      # Every class and module in the file: the lineage is nested three
      # modules deep, and its helper modules carry verbs of their own.
      def index_class_body(program)
        walk(program) do |node|
          next unless (node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)) && node.body

          visibility = :public
          node.body.body.each do |statement|
            case statement
            when Prism::ConstantWriteNode then @constants << statement.name
            when Prism::CallNode
              visibility = statement.name if statement.receiver.nil? && %i[private public].include?(statement.name)
            when Prism::DefNode then @verbs << statement.name if visibility == :public
            else nil
            end
          end
        end
      end

      def each_def(node, &)
        walk(node) { |child| yield child if child.is_a?(Prism::DefNode) }
      end

      def sections(definition)
        found = []
        walk(definition) do |node|
          next unless node.is_a?(Prism::CallNode) && node.name == :synchronize && node.block

          found << node
        end
        found
      end

      def check(section, definition)
        parameters = definition.parameters&.child_nodes&.flatten&.compact&.filter_map do |parameter|
          parameter.name if parameter.respond_to?(:name)
        end || []
        walk(section.block) do |node|
          next unless node.is_a?(Prism::CallNode)
          next if allowed?(node, definition, parameters)

          @violations << Violation.new(method_name: definition.name, line: node.location.start_line,
            text: node.slice)
        end
      end

      def allowed?(call, definition, parameters)
        return true if PURE.include?(call.name)
        return false if call.name == :synchronize

        receiver = call.receiver
        if receiver.nil?
          return !@verbs.include?(call.name)
        end

        root = receiver
        root = root.receiver while root.is_a?(Prism::CallNode) && root.receiver
        case root
        when Prism::InstanceVariableReadNode then true
        when Prism::ConstantReadNode
          @constants.include?(root.name) ||
            (root.name == :Thread && call.name == :new && PARAMETER_SECTIONS.include?(definition.name.to_s))
        when Prism::LocalVariableReadNode
          PARAMETER_SECTIONS.include?(definition.name.to_s) && parameters.include?(root.name)
        when *LITERALS then true
        else false
        end
      end

      def walk(node, &block)
        block.call(node)
        node.compact_child_nodes.each { |child| walk(child, &block) }
      end
  end

  # The suite runs without a locale, so the default external encoding is
  # not UTF-8 and the sources' em-dashes must be read by name.
  def read(path) = File.read(path, encoding: "UTF-8")

  def test_the_monitor_is_the_only_lock_under_the_daemon_tree
    offenders = Dir.glob(File.join(DAEMON_TREE, "**", "*.rb")).select do |path|
      path != LINEAGE && read(path).match?(/\b(Mutex|Monitor)\.new\b/)
    end
    assert_empty offenders, "only lineage.rb may construct a lock"
    assert_equal 1, read(LINEAGE).scan(/\bMonitor\.new\b/).size, "one monitor"
    refute_match(/\bMutex\.new\b/, read(LINEAGE))
  end

  def test_nothing_under_the_monitor_can_do_io_or_call_another_verb
    guard = Guard.new(read(LINEAGE), *LINEAGE_HELPERS.map { |path| read(path) })
    violations = guard.violations

    assert_includes guard.verbs, :adopt, "the guard indexes the public verbs it refuses re-entry to"
    assert_includes guard.verbs, :retire_runs, "the helper modules' verbs are indexed with the class's"
    assert_includes guard.constants, :Workspace, "the guard indexes the value types it allows"
    assert_empty violations.map { |v| "#{v.method_name}:#{v.line} #{v.text}" }
  end

  FIXTURE = <<~RUBY
    class Planted
      Workspace = Data.define(:state)

      def initialize
        @monitor = Monitor.new
        @runs = {}
      end

      def adopt(root)
        @monitor.synchronize do
          FileUtils.mkdir_p(root)
          Thread.new { sleep 1 }
          @runs.clear
          Workspace.new(state: "pending")
        end
      end

      def retire = @monitor.synchronize { @runs = {} }

      def take
        @monitor.synchronize do
          runner = @runs[:runner]
          runner.stop
          retire
        end
      end

      def publish_pending(connection, &work)
        @monitor.synchronize do
          connection.publish_pending(notify: false)
          @poller = Thread.new(&work)
        end
      end

      private

        def helper = @monitor.synchronize { retire_locked }

        def retire_locked = nil
    end
  RUBY

  # THE POSITIVE CASE: a section planting a mkdir, a thread, a call on a
  # local and a verb calling a verb is caught, and the one allowed section
  # is not.
  def test_the_guard_catches_planted_io_threads_locals_and_verb_reentry
    violations = Guard.new(FIXTURE).violations
    texts = violations.map(&:text)

    assert_includes texts, "FileUtils.mkdir_p(root)"
    assert_includes texts, "Thread.new { sleep 1 }"
    assert_includes texts, "runner.stop"
    assert_includes texts, "retire"
    assert_equal %i[adopt adopt take take], violations.map(&:method_name)
    refute(texts.any? { |text| text.include?("publish_pending(notify") },
      "the one section that flips its argument's phase is allowed")
  end
end
