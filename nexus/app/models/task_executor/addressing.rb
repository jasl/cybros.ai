# WHO THIS ADDRESS SERVES AND WHO CONTROLS IT: the profile's or the
# manager's lookup, the eligibility rule every dispatcher reads, and the
# controlling Human's shutdown generation that fences it.
module TaskExecutor::Addressing
  extend ActiveSupport::Concern

  included do
    # A profile's current address; the partial unique index makes this a total
    # lookup. Every writer of an agent address holds the Profile's row lock
    # first — that lock is what lets Consume read an address unlocked.
    scope :addressing, ->(agent) {
      where(agent: agent, executor_kind: :agent_application)
    }
    # One live address per manager/program key; a terminal row is an
    # absence-generation marker for a fresh registration. No ACL scope, and
    # no kind: the key is kind-blind on disk, so a provider and a runner
    # cannot share one, and the kind a re-pair finds is the registration's.
    scope :registered_as, ->(account_id:, manager_id:, registration_identifier:) {
      where(account_id: account_id, executor_kind: TaskExecutor::MACHINE_KINDS, manager_id: manager_id,
        registration_identifier: registration_identifier)
    }
    scope :newest_first, -> { order(created_at: :desc, id: :desc) }
  end

  class_methods do
    def address_for(agent) = live.addressing(agent).first

    # Named definitions share only their declaring program's transport. Direct
    # address lookup remains the credential and announced-document owner.
    def application_address_for(agent)
      owner = agent.application_owner
      address_for(owner) if owner&.active?
    end

    # Includes a terminal address so its last-seen fact survives a revoke;
    # application dispatch uses `application_address_for`.
    def latest_address_for(agent) = addressing(agent).newest_first.first

    def runner_for(**key) = live.registered_as(**key).take

    # A private Runner belongs to a paired application, never a named
    # definition. Its Human continues to own management and credentials.
    def assignment_agent_eligible?(agent, manager:)
      agent&.agent_member? && !agent.named_definition? &&
        agent.execution_principal_eligible? &&
        agent.account_id == manager.account_id && agent.steward_id == manager.id
    end
  end

  # Whether this executor may be addressed with, and claim, work carried
  # under `principal` — side-effect-free, over current rows, the first
  # reader of `assignment_scope`: an `agent_private` Runner serves its paired
  # application's family, a `user_private` machine the Human who manages it
  # and that Human's Agents, and an `account_wide` machine the Account.
  # An agent application's address serves its own and its named definitions'
  # loops whoever authored them; the machine branch is one rule for both machine kinds — a tools
  # provider's pool membership reads exactly this. A page of rows passes
  # the batch projection as `readiness` so the readiness query runs once
  # per page, never once per row.
  def eligible_for?(principal, readiness: nil)
    readiness ||= self.class.credential_readiness_for([self])
    active? &&
      readiness.fetch(id) == :ready &&
      !shutdown_pending? &&
      (agent_application? ? application_serves?(principal) : machine_serves?(principal))
  end

  # The one ownership predicate every machine site reads: a runner and a
  # tools provider answer to their manager Human; only an agent
  # application answers to a Profile's steward.
  def machine? = TaskExecutor::MACHINE_KINDS.include?(executor_kind)

  def controlling_human
    machine? ? manager : agent&.steward
  end

  def shutdown_pending?
    human = controlling_human
    human.nil? || shutdown_pending_for?(human)
  end

  def shutdown_pending_for?(human)
    controlling_human_id != human.id ||
      applied_human_shutdown_generation !=
        human.managed_resource_shutdown_generation
  end

  # Narrower than the publication gate: suspension does not disable an
  # account-wide Runner for others, removal does, and a remove/restore cycle
  # stays fenced until its generation is applied.
  def connection_authority_open?
    human = controlling_human
    !revoked? && human.present? && !human.removed? &&
      !shutdown_pending_for?(human)
  end

  # Rebinding commands call this only after locking the old and new Humans and
  # the address, and after updating the Profile/manager relationship in the
  # same transaction.
  def adopt_human_shutdown_generation(human)
    unless controlling_human_id == human.id
      raise ArgumentError, "Human does not control this TaskExecutor"
    end

    update!(
      applied_human_shutdown_generation:
        human.managed_resource_shutdown_generation
    )
  end

  private

    def application_serves?(principal)
      agent.active? && principal.execution_principal_eligible? &&
        principal.application_owner&.id == agent_id
    end

    def machine_serves?(principal)
      if agent_private?
        assignment_agent.active? && assignment_agent.steward_id == manager_id &&
          principal.execution_principal_eligible? &&
          principal.application_owner&.id == assignment_agent_id
      else
        account_wide? || manager_id == controlling_human_id_of(principal)
      end
    end

    def controlling_human_id
      machine? ? manager_id : agent&.steward_id
    end

    # The Human a principal's work answers to: its steward for an agent,
    # itself for a Human (a Human manages itself).
    def controlling_human_id_of(principal)
      principal.agent? ? principal.steward_id : principal.id
    end

    def freeze_initial_human_shutdown_generation
      human = controlling_human
      return unless human

      self.applied_human_shutdown_generation =
        human.managed_resource_shutdown_generation
    end
end
