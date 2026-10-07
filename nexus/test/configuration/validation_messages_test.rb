require "test_helper"
require "prism"

# Validation errors carry symbol types and I18n, not inline English. A symbol nobody translated
# reaches the wire as "Translation missing: en.activerecord…", so every type a model adds must
# resolve — through its own attribute key, an ancestor's, or the shared `errors.messages` defaults.
class ValidationMessagesTest < ActiveSupport::TestCase
  MODELS = Rails.root.glob("app/models/**/*.rb").sort

  class ErrorAddVisitor < Prism::Visitor
    attr_reader :adds

    def initialize(path)
      @path = path
      @scope = []
      @adds = []
    end

    def visit_class_node(node)
      @scope.push(node.constant_path.slice)
      super
    ensure
      @scope.pop
    end

    def visit_module_node(node)
      @scope.push(node.constant_path.slice)
      super
    ensure
      @scope.pop
    end

    def visit_call_node(node)
      if node.name == :add && node.receiver&.slice == "errors"
        attribute, type = node.arguments&.arguments&.first(2)
        @adds << [@path, node.location.start_line, @scope.join("::"), attribute&.slice, type]
      end
      super
    end
  end

  test "every error type a model adds is a translated symbol" do
    adds = MODELS.flat_map do |path|
      visitor = ErrorAddVisitor.new(path.relative_path_from(Rails.root).to_s)
      Prism.parse(path.read).value.accept(visitor)
      visitor.adds
    end
    assert_not_empty adds

    inline = adds.select { |*, type| type.instance_of?(Prism::StringNode) || type.instance_of?(Prism::InterpolatedStringNode) }
    assert_empty inline.map { |path, line, *| "#{path}:#{line}" },
      "inline English on a validation error; add a symbol type and its config/locales key"

    untranslated = adds.filter_map do |path, line, scope, attribute, type|
      next unless type.instance_of?(Prism::SymbolNode)

      model = translating_model(scope.constantize)
      key = type.unescaped
      attribute_name = attribute.delete_prefix(":")
      keys = model.lookup_ancestors.flat_map do |ancestor|
        ["activerecord.errors.models.#{ancestor.model_name.i18n_key}.attributes.#{attribute_name}.#{key}",
          "activerecord.errors.models.#{ancestor.model_name.i18n_key}.#{key}"]
      end
      keys.push("activerecord.errors.messages.#{key}", "errors.messages.#{key}")
      next if keys.any? { |k| I18n.exists?(k, :en) }

      "#{scope} #{attribute_name} :#{key}"
    end

    assert_empty untranslated.uniq,
      "these symbol types have no message and would render as a missing translation"
  end

  private

    # A concern namespaced under its model (`User::Handle`) adds errors on
    # the model's behalf: the keys are looked up from the nearest enclosing
    # constant that translates.
    def translating_model(constant)
      constant = constant.module_parent until constant.respond_to?(:lookup_ancestors) || constant == Object
      assert_respond_to constant, :lookup_ancestors, "no translating model encloses #{constant}"
      constant
    end
end
