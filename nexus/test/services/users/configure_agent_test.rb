require "test_helper"

class Users::ConfigureAgentTest < ActiveSupport::TestCase
  CONFIGURATION = {
    tool_definitions: [], approval_mode: nil, approval_rules: nil,
    prompt_mechanism: "default", prompt_template: nil, compaction_policy: nil,
  }.freeze

  setup do
    @owner = users(:owner)
    @agent = users(:agent)
  end

  test "a later document refusal rolls back the configuration and earlier replacement document" do
    assert_predicate configure(system_prompt: { content: "Original" }, summarizer: { content: "Summary" }), :accepted?
    before = snapshot
    outcome = configure(
      configuration: CONFIGURATION.merge(conversation_reach: "subtree"),
      system_prompt: { content: "Replacement" }, summarizer: { content: "Invalid {{agent}}" })
    assert_equal :prompt_document_macro_unknown, outcome.outcome
    assert_equal before, snapshot
    assert_equal "Original", @agent.prompt_documents.find_by!(slot: "system_prompt").content
    assert_equal "Summary", @agent.prompt_documents.find_by!(slot: "summarizer").content
  end

  test "the snapshot reads the complete declaration in one unlocked statement" do
    assert_predicate configure(system_prompt: { content: "Original" }, summarizer: { content: "Summary" }), :accepted?
    statements = []
    observer = ->(*, payload) { statements << payload.fetch(:sql) unless payload[:name] == "SCHEMA" }
    snapshot = ActiveSupport::Notifications.subscribed(observer, "sql.active_record") do
      Users::AgentConfigurationSnapshot.read(scope: @owner.stewarded_agents.where(public_id: @agent.public_id))
    end
    assert_equal 1, statements.grep(/\bSELECT\b/i).length
    assert_empty statements.grep(/\b(?:UPDATE|INSERT|DELETE|FOR UPDATE|FOR SHARE)\b/i)
    assert_equal "Original", AgentConfiguration.capture(snapshot).system_prompt.content
    assert_equal "Summary", AgentConfiguration.capture(snapshot).summarizer.content
  end

  test "only an eligible Agent may declare configuration" do
    assert_equal :not_agent, Users::ConfigureAgent.call(user: @owner, configuration: CONFIGURATION).outcome
    @agent.remove
    assert_equal :not_authorized, configure.outcome
  end

  private

    def configure(configuration: CONFIGURATION, **options)
      Users::ConfigureAgent.call(user: @agent, configuration: configuration, **options)
    end

    def snapshot
      AgentConfiguration.capture(Users::AgentConfigurationSnapshot.read(scope: User.where(id: @agent.id))).as_json
    end
end
