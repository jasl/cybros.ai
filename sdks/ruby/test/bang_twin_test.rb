require "test_helper"
require "prism"

# `!` marks the dangerous twin of a method that also exists without it —
# never a destructive action on its own.
class BangTwinTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SOURCES = Dir[File.join(ROOT, "lib/**/*.rb")].sort

  class DefinitionVisitor < Prism::Visitor
    attr_reader :definitions

    def initialize
      super
      @scope = []
      @definitions = []
    end

    def visit_class_node(node) = within(node.constant_path.slice) { super }
    def visit_module_node(node) = within(node.constant_path.slice) { super }
    def visit_singleton_class_node(node) = within("class << self") { super }

    def visit_def_node(node)
      @definitions << [@scope.join("::"), node.receiver.nil?, node.name.to_s, node.location.start_line]
      super
    end

    private

    def within(name)
      @scope.push(name)
      yield
    ensure
      @scope.pop
    end
  end

  def test_every_bang_method_has_a_non_bang_twin_in_the_same_scope
    violations = SOURCES.flat_map do |path|
      violations_in(path.delete_prefix("#{ROOT}/"), File.read(path))
    end

    assert_empty violations, <<~MESSAGE
      A `!` promises a non-bang twin beside it. Drop the bang (raising or
      writing is the method's only contract) or add the twin a caller wants:
      #{violations.join("\n")}
    MESSAGE
  end

  def test_the_guard_flags_a_bang_without_a_twin_and_nothing_else
    source = <<~RUBY
      module Probe
        class Thing
          def seal! = nil
          def seal = nil
          def decode!(value) = value
          def self.boot! = nil
          class << self
            def current! = nil
          end
        end
        def self.boot = nil
      end
    RUBY

    assert_equal [
      "probe.rb:5: Probe::Thing#decode!",
      "probe.rb:6: Probe::Thing.boot!",
      "probe.rb:8: Probe::Thing::class << self#current!",
    ], violations_in("probe.rb", source)
  end

  private

  def violations_in(path, source)
    visitor = DefinitionVisitor.new
    Prism.parse(source).value.accept(visitor)
    defined = visitor.definitions.to_set { |scope, instance, name, _| [scope, instance, name] }

    visitor.definitions.filter_map do |scope, instance, name, line|
      next unless name.end_with?("!")
      next if defined.include?([scope, instance, name.delete_suffix("!")])

      "#{path}:#{line}: #{scope}#{instance ? "#" : "."}#{name}"
    end
  end
end
