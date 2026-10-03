module Workspace::Access
  extend ActiveSupport::Concern

  MODEL_WORK_LOSING_ACCESS_SQL = <<~SQL.squish.freeze
    EXISTS (
      SELECT 1
      FROM users AS principals
      LEFT JOIN users AS stewards ON stewards.id = principals.steward_id
      WHERE principals.id = model_invocations.creating_user_id
        AND principals.account_id = ?
        AND principals.status = 'active'
        AND (
          (
            principals.kind = 'human'
            AND (? OR principals.id = ?)
            AND NOT (? OR principals.id = ?)
          )
          OR
          (
            principals.kind = 'agent'
            AND principals.role <> 'system'
            AND stewards.account_id = ?
            AND stewards.kind = 'human'
            AND stewards.status = 'active'
            AND principals.applied_steward_shutdown_generation =
              stewards.managed_resource_shutdown_generation
            AND (? OR stewards.id = ?)
            AND NOT (? OR stewards.id = ?)
          )
        )
    )
  SQL

  class_methods do
    # The one composable data relation: no query uses creator, Account role
    # or an old steward.
    def data_accessible_to(user)
      if user.human?
        if user.active?
          in_account = where(account_id: user.account_id)
          in_account.where(owner_id: user.id).or(in_account.where(access_mode: :account_wide))
        else
          none
        end
      elsif user.agent_member?
        if user.active? && user.steward_live?
          data_accessible_to(user.steward)
        else
          none
        end
      else
        none
      end
    end
  end

  # The same relation, answered for one row without a query.
  def data_accessible_by?(user)
    if user.human?
      user.active? && user.account_id == account_id &&
        (owner_id == user.id || account_wide?)
    elsif user.agent_member?
      user.active? && user.steward_live? && data_accessible_by?(user.steward)
    else
      false
    end
  end

  # The dedication fence: an identifier-tagged Workspace refuses mismatched
  # Agent writes. Reads never consult it and Humans are never fenced. A
  # named definition is judged by its ROOT identifier — its declarer's, so
  # an instance-scoped row answers in its parent's dedicated workspace — and
  # a PUBLISHED one is never fenced: the fence keeps mismatched PROGRAMS'
  # writes out, and a published row is no program (no credential, no
  # address); its writes land through the spawner's own bound runner.
  def dedication_fenced_against?(user)
    if agent_identifier.nil?
      false
    else
      user.agent_member? && !user.published? && user.root_identifier != agent_identifier
    end
  end

  # The composed write/admission answer: current access on a live Workspace
  # with the fence applied. Data writes only — management is separate below.
  def data_writable_by?(user)
    live? && data_accessible_by?(user) && !dedication_fenced_against?(user)
  end

  # WHO MAY ANSWER A CONVERSATION HERE: an agent profile of the account that
  # may write in this workspace — live, reachable through its steward, not
  # dedication-fenced (it will write turns and effects). A Human, the system
  # user, a suspended or fenced profile all answer no. The create door names
  # the default with it; the input door conjoins the row's level
  # (`Conversation#answerer_eligible?`).
  def answerer_eligible?(user) = user&.agent_member? == true && data_writable_by?(user)

  # THE ONE WRITE PREDICATE'S NAME on every host: a workspace answers its
  # own data rule; a conversation conjoins it with the caller's level on
  # the row; a loop answers as its host does. One name, so a door's
  # `authorize_writable(host)` never branches on a type.
  def writable_by?(user) = data_writable_by?(user)

  # The principals whose access this change ended: a difference between two relations, never
  # "who is absent now" — a suspended principal may hold live work outside the relation and is
  # another owner's to cut.
  def model_work_losing_access(previously:)
    ModelInvocation.where(workspace_id: id).where(
      MODEL_WORK_LOSING_ACCESS_SQL,
      account_id,
      previously.account_wide?, previously.owner_id,
      account_wide?, owner_id,
      account_id,
      previously.account_wide?, previously.owner_id,
      account_wide?, owner_id
    )
  end

  # Management is identity, not state: active Human owner only.
  # Command-level state preconditions stay with each command.
  def manageable_by?(user)
    user.human? && user.active? && owner_id == user.id
  end
end
