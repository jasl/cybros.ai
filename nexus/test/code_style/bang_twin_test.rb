require "test_helper"
require "prism"

# `!` marks the dangerous twin of a method that also exists without it — never a destructive action
# on its own. A lone `decode` says "there is a gentler `decode`" and there is not, so the reader
# goes looking for a contract that does not exist.
class BangTwinTest < ActiveSupport::TestCase
  SOURCES = Rails.root.glob("{app,lib}/**/*.rb").sort

  # Rails-defined bangs the code overrides: their contract is the
  # framework's, where this guard cannot see it. name => one-line reason.
  INHERITED_TWINS = {
    "check_validity!" => "ActiveModel::EachValidator's declaration hook, named by the framework",
  }.freeze

  class DefinitionVisitor < Prism::Visitor
    attr_reader :definitions

    def initialize
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

  test "every bang method has a non-bang twin in the same class or module" do
    violations = SOURCES.flat_map { |path| violations_in(path.relative_path_from(Rails.root), path.read) }

    assert_empty violations, <<~MESSAGE
      A `!` promises a non-bang twin beside it. Drop the bang (raising or
      writing is the method's only contract) or add the twin a caller wants;
      never use `!` merely to mark a destructive action:
      #{violations.join("\n")}
    MESSAGE
  end

  # The guard's own fixture: it must see a lone bang, and must not mistake a
  # twin in another scope, or an allowlisted framework hook, for one.
  test "the guard flags a bang without a twin and nothing else" do
    source = <<~RUBY
      module Probe
        class Thing
          def seal! = nil
          def seal = nil
          def decode!(value) = value
          def self.boot! = nil
          def check_validity! = nil
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
      "probe.rb:9: Probe::Thing::class << self#current!",
    ], violations_in("probe.rb", source)
  end

  private

    def violations_in(path, source)
      visitor = DefinitionVisitor.new
      Prism.parse(source).value.accept(visitor)
      defined = visitor.definitions.to_set { |scope, instance, name, _| [scope, instance, name] }

      visitor.definitions.filter_map do |scope, instance, name, line|
        next unless name.end_with?("!")
        next if INHERITED_TWINS.key?(name)
        next if defined.include?([scope, instance, name.delete_suffix("!")])

        "#{path}:#{line}: #{scope}#{instance ? "#" : "."}#{name}"
      end
    end
end
