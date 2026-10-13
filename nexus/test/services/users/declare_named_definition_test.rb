require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

# THE NAMED DEFINITION'S ONE WRITER: the find-or-new by the composed identifier, the restore, the
# lock on a found row, the one `declare_configuration`, the slot write, one transaction — and every
# refusal the door relays.
class Users::DeclareNamedDefinitionTest < ActiveSupport::TestCase
  include RunLaneTestHelper
  include RowLockTestHelper

  uses_transaction :test_removal_that_locks_first_fences_an_in_flight_new_definition_declaration

  setup do
    @owner = users(:owner)
    @agent = users(:agent)
    DevModelLane.ensure_enabled!(accounts(:cybros))
  end

  CONFIGURATION = {
    tool_definitions: [RunLaneTestHelper::READ_TOOL], approval_mode: "bypass", approval_rules: nil,
    prompt_mechanism: "default", prompt_template: nil, compaction_policy: { "mode" => "kernel" }, default_model: nil,
  }.freeze

  def declare(name = "reviewer", caller: @agent, scope: "instance", description: "Reviews a diff.",
              system_prompt: "You are a reviewer.", **rest)
    Users::DeclareNamedDefinition.call(caller: caller, name: name, scope: scope, description: description,
      system_prompt: system_prompt, configuration: CONFIGURATION, **rest)
  end

  test "mints the row: the composed identifier, the caller as declarer, the steward's, the name as handle and display name, the slot" do
    outcome = declare
    assert_equal :declared, outcome.outcome
    assert_predicate outcome, :accepted?

    row = outcome.user
    assert_predicate row, :persisted?
    assert_equal "#{@agent.agent_identifier}/reviewer", row.agent_identifier
    assert_equal @agent, row.derived_from
    assert_equal "instance", row.definition_scope
    assert_predicate row, :named_definition?
    assert_not_predicate row, :published?
    assert_equal [@owner, "agent", "member", "active"], [row.steward, row.kind, row.role, row.status]
    assert_equal "reviewer", row.handle
    assert_equal "reviewer", row.display_name
    assert_equal "reviewer", row.definition_name
    assert_equal "Reviews a diff.", row.description
    assert_nil row.identity
    assert_equal %w[read_file], row.tool_definitions.map { |tool| tool.dig("function", "name") }
    assert_equal "You are a reviewer.", row.prompt_documents.find_by!(slot: "system_prompt").content
    assert_includes @agent.named_definitions, row
  end

  test "a second declaration replaces the same row whole; the scope flips; nil body deletes the slot" do
    first = declare.user
    outcome = declare(scope: "steward", description: "Reviews.", system_prompt: nil, display_name: "The reviewer")

    assert_equal :replaced, outcome.outcome
    assert_equal first, outcome.user
    row = outcome.user.reload
    assert_equal [first.handle, first.public_id, first.agent_identifier], [row.handle, row.public_id, row.agent_identifier]
    assert_predicate row, :published?
    assert_equal ["The reviewer", "Reviews."], [row.display_name, row.description]
    assert_not row.prompt_documents.exists?(slot: "system_prompt")
    assert_equal 1, @agent.named_definitions.count
  end

  test "the same row restores after a removal: replaced, active, the same handle" do
    row = declare.user
    assert_equal :removed, row.remove

    outcome = declare
    assert_equal :replaced, outcome.outcome
    assert_equal row, outcome.user
    assert_predicate row.reload, :active?
    assert_equal "reviewer", row.handle
  end

  test "a caller authenticated before its removal cannot create an instance definition afterward" do
    caller = User.find(@agent.id)
    assert_equal :removed, @agent.remove

    assert_no_difference -> { User.count } do
      outcome = declare(caller: caller)
      assert_equal :not_authorized, outcome.outcome
      assert_not_predicate outcome, :accepted?
    end
    assert_not User.exists?(derived_from_id: @agent.id)
  end

  test "a caller authenticated before its removal cannot restore or replace its removed definition" do
    row = declare.user
    caller = User.find(@agent.id)
    assert_equal :removed, @agent.remove
    assert_predicate row.reload, :removed?

    outcome = declare(caller: caller, description: "Replacement.", system_prompt: "Replacement prompt.")
    assert_equal :not_authorized, outcome.outcome
    assert_predicate row.reload, :removed?
    assert_equal "Reviews a diff.", row.description
    assert_equal "You are a reviewer.", row.prompt_documents.find_by!(slot: "system_prompt").content
    assert_not workspaces(:shared).answerer_eligible?(row)

    assert_equal :restored, @agent.restore
    assert_equal :replaced, declare.outcome
    assert_predicate row.reload, :active?
  end

  test "removal after a successful redeclaration removes its result" do
    row = declare.user
    assert_equal :replaced, declare(description: "Replacement.").outcome
    assert_equal :removed, @agent.remove

    assert_predicate row.reload, :removed?
    assert_equal "Replacement.", row.description
    assert_not workspaces(:shared).answerer_eligible?(row)
  end

  test "removal that locks first fences an in flight new definition declaration" do
    profile = create_agent_member(steward: @owner, agent_identifier: "declaration-removal-race")
    held = hold_row_lock(User, profile.id, before_commit: ->(locked) {
      raise "profile removal failed" unless locked.remove == :removed
    })
    declaration = start_database_call do
      declare(caller: User.find(profile.id))
    end
    wait_until_transitively_blocked_by(held.pid, declaration.pid)

    release_row_lock(held)
    held = nil
    assert_equal :not_authorized, finish_database_call(declaration).outcome
    declaration = nil

    assert_predicate profile.reload, :removed?
    assert_not profile.named_definitions.exists?
  ensure
    release_row_lock(held) if held
    stop_database_call(declaration) if declaration
    # This test commits across connections. Destroy through User so its prompt
    # documents leave before fixture reload replaces their owning rows.
    profile&.named_definitions&.destroy_all
    profile&.destroy!
  end

  test "a paired program's row under the composed identifier is never adopted: identifier_taken" do
    paired = create_agent_member(steward: @owner, display_name: "Paired",
      agent_identifier: "#{@agent.agent_identifier}/reviewer")

    outcome = declare
    assert_equal :identifier_taken, outcome.outcome
    assert_equal paired, outcome.user
    assert_nil paired.reload.definition_scope
    assert_equal "Paired", paired.display_name
    assert_not paired.prompt_documents.exists?
  end

  test "a removed row whose steward's generation moved is shutdown_pending, and stays removed" do
    row = declare.user
    row.remove
    User.where(id: row.id).update_all(applied_steward_shutdown_generation: @owner.managed_resource_shutdown_generation - 1)

    assert_equal :shutdown_pending, declare.outcome
    assert_predicate row.reload, :removed?
  end

  test "a reassigned declarer cannot adopt its previous steward's named definition" do
    row = declare.user
    assert_equal :changed, @agent.change_steward(to: users(:member))

    outcome = declare(description: "Attempted replacement")

    assert_equal :identifier_taken, outcome.outcome
    assert_equal row, outcome.user
    assert_equal @owner, row.reload.steward
    assert_equal "Reviews a diff.", row.description
  end

  test "the handle is the name when free, else the kernel's -N; the identifier stays the composition" do
    sibling = create_agent_member(steward: @owner, display_name: "Sibling", agent_identifier: "rho.sibling")
    theirs = declare(caller: sibling).user
    assert_equal "reviewer", theirs.handle

    mine = declare.user
    assert_equal "reviewer-2", mine.handle
    assert_equal "#{@agent.agent_identifier}/reviewer", mine.agent_identifier
    assert_equal "reviewer", mine.definition_name
  end

  test "one transaction: a refused body takes the row with it, and a replaced row keeps its old slot" do
    outcome = declare(system_prompt: "You are {{nobody}}.")
    assert_equal :prompt_document_macro_unknown, outcome.outcome
    assert_equal "nobody", outcome.detail
    assert_not User.exists?(derived_from_id: @agent.id)

    row = declare.user
    outcome = declare(system_prompt: "Still {{nobody}}.", description: "Changed.")
    assert_equal :prompt_document_macro_unknown, outcome.outcome
    assert_equal "Reviews a diff.", row.reload.description, "the replacement rolled back whole"
    assert_equal "You are a reviewer.", row.prompt_documents.find_by!(slot: "system_prompt").content
  end

  test "a named definition's refused default model rolls back creation or replacement whole" do
    configuration = CONFIGURATION.merge(default_model: "dev/no-such-model")
    outcome = declare(configuration: configuration)
    assert_equal :invalid, outcome.outcome
    assert outcome.user.errors.added?(:default_model, :not_authorized, refusal: :unknown_model)
    assert_not User.exists?(derived_from_id: @agent.id)

    row = declare(configuration: CONFIGURATION.merge(default_model: "dev/mock-text")).user
    outcome = declare(configuration: configuration, description: "Changed.", system_prompt: "Replacement.")
    assert_equal :invalid, outcome.outcome
    assert outcome.user.errors.added?(:default_model, :not_authorized, refusal: :unknown_model)
    assert_equal "dev/mock-text", row.reload.default_model
    assert_equal "Reviews a diff.", row.description
    assert_equal "You are a reviewer.", row.prompt_documents.find_by!(slot: "system_prompt").content
  end

  # The validation answers `taken` to the twin it can see; the twin it
  # cannot — two inserts past two green validations — loses on the
  # `(account_id, agent_identifier)` index (the handle precedent pins the
  # index itself) and surfaces as `concurrent_write`, nothing written.
  test "the twin first PUT loses on the unique index as concurrent_write" do
    declare
    outcome = User.stub(:find_by, nil) { declare }
    assert_equal :invalid, outcome.outcome
    assert_includes outcome.user.errors.details.fetch(:agent_identifier).map { _1[:error] }, :taken

    loser = User.new(account: @agent.account, kind: :agent, role: :member, steward: @owner,
      agent_identifier: "#{@agent.agent_identifier}/docs", handle_base: "docs")
    def loser.save(*) = raise(ActiveRecord::RecordNotUnique, "index_users_on_account_agent_identifier")
    outcome = User.stub(:find_by, nil) { User.stub(:new, loser) { declare("docs") } }
    assert_equal :concurrent_write, outcome.outcome
    assert_equal 1, @agent.named_definitions.count
  end

  test "the model owns the refusals: the scope word, the description, a Human caller, a name outside the grammar" do
    outcome = declare(scope: "global")
    assert_equal :invalid, outcome.outcome
    assert_includes outcome.user.errors.details.fetch(:definition_scope).map { _1[:error] }, :inclusion
    assert_not User.exists?(derived_from_id: @agent.id)

    outcome = declare(description: "two\nlines")
    assert_equal :invalid, outcome.outcome
    assert_includes outcome.user.errors.details.fetch(:description).map { _1[:error] }, :invalid
    outcome = declare(description: "")
    assert_equal :invalid, outcome.outcome
    assert_includes outcome.user.errors.details.fetch(:description).map { _1[:error] }, :blank
    outcome = declare(description: "x" * 1025)
    assert_equal :invalid, outcome.outcome
    assert_includes outcome.user.errors.details.fetch(:description).map { _1[:error] }, :too_long

    assert_equal :not_agent, declare(caller: @owner).outcome
    assert_equal :invalid_name, declare("Reviewer").outcome
    assert_equal :invalid_name, declare("reviewer.md").outcome
  end

  test "the row is a definition, never a program: a scope needs a declarer and a declarer a scope; no bearer, no address" do
    row = declare.user
    row.definition_scope = nil
    assert_not row.valid?
    assert_includes row.errors.details.fetch(:definition_scope).map { _1[:error] }, :blank

    orphan = create_agent_member(steward: @owner, display_name: "Orphan", agent_identifier: "orphan")
    orphan.definition_scope = "instance"
    assert_not orphan.valid?
    assert_includes orphan.errors.details.fetch(:derived_from).map { _1[:error] }, :blank

    orphan.derived_from = @owner
    assert_not orphan.valid?, "a Human declares nothing"
    assert_includes orphan.errors.details.fetch(:derived_from).map { _1[:error] }, :invalid

    @owner.description = "a person"
    assert_not @owner.valid?
    assert_includes @owner.errors.details.fetch(:description).map { _1[:error] }, :present
  end
end
