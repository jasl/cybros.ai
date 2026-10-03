require "test_helper"

# The seven non-STI lifecycle columns are string-backed enums over the
# model's own vocabulary (idiom #3): the mapping IS the constant, an
# unknown word is the same `:inclusion` error the hand validation gave,
# never an ArgumentError on assignment, and no scope is minted for a value.
class LifecycleEnumsTest < ActiveSupport::TestCase
  LIFECYCLES = {
    UsageRecord => [:status, UsageRecord::STATUSES],
    ModelProviderOAuthSession => [:state, ModelProviderOAuthSession::STATES],
    ConversationInput => [:state, ConversationInput::STATES],
    ConversationTurn => [:status, ConversationTurn::STATUSES],
    ConversationTurnVariant => [:status, ConversationTurnVariant::STATUSES],
    AgentLoop => [:status, AgentLoop::STATUSES],
    ModelProviderOAuthTask => [:state, ModelProviderOAuthTask::STATES],
  }.freeze

  test "each lifecycle column is an enum over the model's own vocabulary" do
    LIFECYCLES.each do |model, (column, vocabulary)|
      mapping = model.defined_enums.fetch(column.to_s) { flunk "#{model} has no #{column} enum" }
      assert_equal vocabulary, mapping.keys, model.name
      assert_equal vocabulary, mapping.values, "#{model.name}: string-backed, the word is the value"
    end
  end

  test "an unknown word validates as :inclusion and mints no scope" do
    LIFECYCLES.each do |model, (column, vocabulary)|
      record = model.new(column => "nonesuch")
      assert_equal "nonesuch", record.public_send(column), "#{model.name}: kept for the error, never raised"
      record.validate
      assert record.errors.of_kind?(column, :inclusion), model.name
      assert_not model.respond_to?(:"not_#{vocabulary.first}"), "#{model.name}: scopes: false"
    end
  end
end
