# The member/data-authority kill switch: suspend and remove advance the authority
# generation in the same UPDATE, so every earlier credential is born fenced. Removal is a
# recoverable access state, never a data operation.
module User::Lifecycle
  def suspend
    # Suspension is human-only ("temporarily locked, expected back"); an
    # agent's lifecycle is remove/restore.
    return :not_applicable if agent?

    # A single-row lock suffices: the owner is undemotable and always an
    # active admin, so the active-admin set can never empty.
    with_lock do
      blocked = administration_block
      if blocked
        blocked
      elsif !active?
        :not_active
      else
        update!(status: :suspended, authority_generation: authority_generation + 1)
        :suspended
      end
    end
  end

  def reactivate
    return :not_applicable if agent?

    # A lifecycle move inside the model, not a CAS: the verb names which
    # precondition failed, which 0 rows changed cannot say.
    with_lock do
      if !suspended?
        :not_suspended
      else
        # No generation advance: pre-suspension credentials stay dead under
        # their superseded snapshots and must be re-minted.
        update!(status: :active)
        :reactivated
      end
    end
  end

  def remove
    # `administration_block` reads sibling rows (the last active admin,
    # the owner's protection) and the verb names which one refused — a
    # cross-row predicate no CAS on this row can carry.
    with_lock do
      blocked = administration_block
      if blocked
        blocked
      elsif removed?
        :not_active
      elsif human? && account.workspaces.non_tombstoned.where(owner: self).exists?
        # Removal waits for every owned Workspace to transfer or tombstone;
        # suspend never consults ownership. Every Workspace create/transfer
        # locks its owner, so none slips past this lock.
        :workspace_ownership_transfer_required
      else
        # A suspended member departing is ordinary, so remove accepts both
        # live states. The Identity link survives — recoverability requires
        # it; the status check blocks login and the email stays reserved.
        update!(
          status: :removed,
          authority_generation: authority_generation + 1,
          **(human? ? { managed_resource_shutdown_generation: managed_resource_shutdown_generation + 1 } : {})
        )
        revoke_agent_credentials if agent?
        # Record the existing model cancellation intent with one set update;
        # stopping related conversation/loop aggregates happens after commit.
        ModelInvocation::Cancellation.call(
          scope: ModelInvocation.where(creating_user_id: id),
          reason: "user_removed",
          source_user_authority_generation: authority_generation
        )
        remove_instance_definitions if agent?
        :removed
      end
    end
  end

  def restore
    # The steward's liveness is read on another row and the verb names it
    # (`:shutdown_pending`); a CAS on `status` alone could not.
    with_lock do
      if !removed?
        :not_removed
      elsif agent_member? && !steward_live?
        :shutdown_pending
      else
        # No generation advance, mirroring reactivate: restore reopens
        # access, never resurrects pre-removal member/data authority.
        update!(status: :active)
        :restored
      end
    end
  end

  private

    # Removal fences both Agent planes atomically while retaining its address
    # for reconnect. Work stops asynchronously.
    def revoke_agent_credentials
      TaskExecutor.address_for(self)&.revoke_credentials
    end

    # THE NAMED DEFINITIONS GO WITH THEIR DECLARER: the instance-scoped rows
    # flip to removed under the parent's lock, each through its own `remove`
    # — ascending id after the parent, every named row minted after it, so
    # `PrincipalLocks`' order holds; a published row survives and the
    # human's page removes it. `restore` restores none downstream: the next
    # boot's declare edge re-declares from the files.
    def remove_instance_definitions
      named_definitions.where(definition_scope: "instance", status: :active).order(:id).each(&:remove)
    end

    def administration_block
      if system?
        :not_administrable
      elsif owner?
        :owner_protected
      elsif last_active_admin?
        # Keep the last-administrator refusal explicit even though an active
        # owner normally prevents this branch from being reached.
        :last_admin
      end
    end
end
