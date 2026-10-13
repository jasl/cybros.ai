require "test_helper"

class ExecutionDeclarationTest < ActiveSupport::TestCase
  test "delegation catalogs keep complete leaf declarations and distinguish empty from unrestricted" do
    leaf = { "default_model" => "dev/mock-text", "system_prompt" => { "content" => "Review the supplied task." } }
    declaration = ExecutionDeclaration.new(delegation_catalog: [
      { "name" => "reviewer", "description" => "Reviews changes", "model_mode" => "caller", "declaration" => leaf },
    ])
    assert_predicate declaration, :valid?, declaration.errors.full_messages.to_sentence
    assert_equal "Review the supplied task.", declaration.delegation_catalog.sole.declaration.system_prompt.content
    assert_nil ExecutionDeclaration.new.delegation_catalog
    assert_equal [], ExecutionDeclaration.new(delegation_catalog: []).delegation_catalog

    declaration.delegation_catalog << declaration.delegation_catalog.first
    refute_predicate declaration, :valid?
    declaration.delegation_catalog = [declaration.delegation_catalog.first]
    declaration.delegation_catalog.first.declaration.delegation_catalog = []
    refute_predicate declaration, :valid?, "a leaf cannot carry a second delegation directory"
  end

  test "a declaration validates tools, approval, template macros and ordered references as one value" do
    declaration = ExecutionDeclaration.new(kernel_tools: ["nexus.memory.read"], approval_mode: "rules",
      default_model: "dev/mock-text", fallback_models: %w[dev/mock-priced dev/mock-unmetered],
      system_prompt: { content: "You are {{agent}}.", role: "system" })
    assert_predicate declaration, :valid?, declaration.errors.full_messages.to_sentence
    assert_equal %w[dev/mock-priced dev/mock-unmetered], declaration.fallback_models

    declaration.approval_mode = nil
    refute_predicate declaration, :valid?
    assert declaration.errors.of_kind?(:approval_mode, :blank)
    declaration.approval_mode = "bypass"
    declaration.system_prompt.content = "You are {{undeclared}}."
    refute_predicate declaration, :valid?
    assert declaration.errors.of_kind?(:system_prompt, :invalid)
    declaration.system_prompt.content = "Ready."
    declaration.fallback_models = ["missing-provider"]
    refute_predicate declaration, :valid?
    assert declaration.errors.of_kind?(:fallback_models, :invalid)
  end

  test "captured documents require content and enforce the prompt byte bound" do
    empty = ExecutionDeclaration::Document.new(content: "")
    assert_predicate empty, :valid?
    refute_predicate ExecutionDeclaration::Document.new, :valid?
    bound = Nexus::SizeBounds.fetch(:prompt_document_bound)
    large = ExecutionDeclaration::Document.new(content: "界" * (bound / 3 + 1))
    refute_predicate large, :valid?
    assert large.errors.of_kind?(:content, Nexus::SizeBounds::REJECTION)
    refute_predicate ExecutionDeclaration::Document.new(content: "a\u0000b"), :valid?
  end

  test "selection intent retains an explicit default choice and validates its closed vocabulary" do
    intent = ModelSelectionIntent.explicit("dev/mock-text")
    assert_predicate intent, :valid?
    assert_equal "explicit", intent.source
    assert_equal "route", intent.constraint
    assert_equal "dev/mock-text", intent.model
    intent.constraint = "model"
    intent.alternatives = ["other/model-version"]
    assert_predicate intent, :valid?
    intent.source = "guess"
    refute_predicate intent, :valid?
    intent.source = "inherited"
    intent.alternatives = "other/model-version"
    refute_predicate intent, :valid?
  end
end
