# WHO THIS ADDRESS SERVES AND WHO CONTROLS IT: the profile's or the
# manager's lookup, the eligibility rule every dispatcher reads, and the
# controlling Human's shutdown generation that fences it.
module TaskExecutor::Addressing
  extend ActiveSupport::Concern

  included do
    # A profile's current address; the partial unique index makes this a total
    # lookup. Every writer of an agent address holds the Profile's row lock
    # first — that lock is what lets Consume read an address unlocked.
    scope :addressing, ->(agent_profile) {
      where(agent_profile: agent_profile, executor_kind: :agent_application)
    }
    # One live address per manager/program key; a terminal row is an
    # absence-generation marker for a fresh registration. No ACL scope, and
    # no kind: the key is kind-blind on disk, so a provider and a runner
    # cannot share one, and the kind a re-pair finds is the registration's.
    scope :registered_as, ->(account_id:, manager_id:, runner_identifier:) {
      where(account_id: account_id, executor_kind: TaskExecutor::MACHINE_KINDS, manager_id: manager_id,
        runner_identifier: runner_identifier)
    }
    scope :newest_first, -> { order(created_at: :desc, id: :desc) }
  end

  class_methods do
    def address_for(agent_profile) = live.addressing(agent_profile).first

    # Includes a terminal address so its last-seen fact survives a revoke;
    # dispatch uses `address_for`.
    def latest_address_for(agent_profile) = addressing(agent_profile).newest_first.first

    def runner_for(**key) = live.registered_as(**key).take
  end

  # Whether this executor may be addressed with, and claim, work carried
  # under `principal` — side-effect-free, over current rows, the first
  # reader of `assignment_scope`: a `user_private` machine serves only the
  # work of the Human who manages it and of the agents that Human stewards.
  # An agent application's address serves its own loops whoever authored
  # them; the machine branch is one rule for both machine kinds — a tools
  # provider's pool membership reads exactly this. A page of rows passes
  # the batch projection as `readiness` so the readiness query runs once
  # per page, never once per row.
  def eligible_for?(principal, readiness: nil)
    readiness ||= self.class.credential_readiness_for([self])
    active? &&
      readiness.fetch(id) == :ready &&
      !shutdown_pending? &&
      (!agent_application? || agent_profile.active?) &&
      (agent_application? || account_wide? || manager_id == controlling_human_id_of(principal))
  end

  # The one ownership predicate every machine site reads: a runner and a
  # tools provider answer to their manager Human; only an agent
  # application answers to a Profile's steward.
  def machine? = TaskExecutor::MACHINE_KINDS.include?(executor_kind)

  def controlling_human
    machine? ? manager : agent_profile&.steward
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

    def controlling_human_id
      machine? ? manager_id : agent_profile&.steward_id
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
