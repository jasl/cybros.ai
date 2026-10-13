require "test_helper"
require "prism"

class ClosedInternalShapesTest < ActiveSupport::TestCase
  TYPE_PROBE_PATTERN = /\.(?:is_a\?|kind_of\?|instance_of\?|respond_to\?)/
  TYPE_CASE_CONSTANTS = %i[Array Float Hash Integer Numeric String Symbol].freeze
  APPLICATION_FILES = Rails.root.glob("app/**/*.{rb,erb}").sort
  APPLICATION_RUBY_FILES = Rails.root.glob("app/**/*.rb").sort

  class DisguisedTypeProbeVisitor < Prism::Visitor
    attr_reader :violations

    def initialize(path)
      @path = path
      @method_names = []
      @violations = []
    end

    def visit_def_node(node)
      @method_names << node.name
      super
    ensure
      @method_names.pop
    end

    def visit_case_node(node)
      method_name = @method_names.last
      if method_name.to_s.end_with?("?") && type_case?(node)
        @violations << "#{@path}:#{node.location.start_line}: #{method_name}"
      end
      super
    end

    def visit_call_node(node)
      receiver = node.receiver
      if node.name == :=== && receiver.instance_of?(Prism::ConstantReadNode) &&
          TYPE_CASE_CONSTANTS.include?(receiver.name)
        @violations << "#{@path}:#{node.location.start_line}: #{receiver.name} ==="
      end
      super
    end

    private

      def type_case?(node)
        constants = node.conditions.flat_map(&:conditions).filter_map do |condition|
          condition.name if condition.instance_of?(Prism::ConstantReadNode)
        end
        (constants & TYPE_CASE_CONSTANTS).any?
      end
  end

  test "application code does not probe trusted internal types" do
    violations = APPLICATION_FILES.flat_map do |path|
      path.each_line.with_index(1).filter_map do |line, line_number|
        next unless line.match?(TYPE_PROBE_PATTERN)

        "#{path.relative_path_from(Rails.root)}:#{line_number}: #{line.strip}"
      end
    end

    assert_empty violations, <<~MESSAGE
      Normalize inputs at their boundary and trust the resulting type. Use an
      exhaustive case expression only when a value has a real closed union —
      and never launder the probe into `case x when String` instead: normalize
      (`to_s`/`to_h`/`fetch`) or remove the redundant internal check:
      #{violations.join("\n")}
    MESSAGE
  end

  test "application code does not disguise type probes" do
    violations = APPLICATION_RUBY_FILES.flat_map do |path|
      parsed = Prism.parse_file(path.to_s)
      assert_predicate parsed, :success?, "#{path.relative_path_from(Rails.root)} must parse"

      visitor = DisguisedTypeProbeVisitor.new(path.relative_path_from(Rails.root))
      visitor.visit(parsed.value)
      visitor.violations
    end

    assert_empty violations, <<~MESSAGE
      A concrete-type question may not be spelled as `String === value`, or
      hidden inside a predicate as `case value when String`. Normalize at the
      input boundary and ask about the normalized value's domain semantics:
      #{violations.join("\n")}
    MESSAGE
  end
end
