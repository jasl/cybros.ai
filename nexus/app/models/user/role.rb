module User::Role
  extend ActiveSupport::Concern

  ASSIGNABLE_ROLES = %w[member admin].freeze

  included do
    enum :role, %w[owner admin member system].index_by(&:itself), default: :member, validate: true, scopes: false

    # Fizzy-style composed role scopes: owner bakes the active filter in, so
    # a suspended owner never satisfies an owner lookup even when the caller
    # does not compose active itself.
    scope :active, -> { where(status: :active) }
    scope :owner, -> { active.where(role: :owner) }

    # An owner has every admin capability; predicates lean on admin? so owners
    # pass transparently. Defined in the included block so it overrides the
    # enum-generated method and super reaches it (Fizzy User::Role shape).
    def admin?
      super || owner?
    end
  end

  # The device-flow human-presence boundary: administrators follow the same
  # rule as members; agent principals and every bearer are excluded.
  def active_human_member?
    human? && active?
  end

  # An ordinary Agent: agent kind excluding the synthetic system
  # user, which shares kind: agent without being a product principal. The
  # one domain predicate for the concept — never re-derive it inline.
  def agent_member?
    agent? && !system?
  end


  # Fizzy's can_administer? shape: an admin acting on a non-owner member
  # other than themselves. Owner transfer has its own owner-only verb.
  def administrable_by?(actor)
    actor.admin? && !owner? && actor != self
  end

  def last_active_admin?
    admin? && active? && account.users.active.where(role: %w[owner admin]).where.not(id: id).none?
  end

  # member <-> admin only; owner moves solely through the indivisible
  # transfer and system is never assigned. Guards re-check in the row lock
  # per the acceptance-order winner rule.
  def change_role(to:)
    target_role = to.to_s

    if !target_role.in?(ASSIGNABLE_ROLES)
      :invalid_role
    elsif agent?
      :not_administrable
    else
      # `last_active_admin?` counts sibling rows and the verb names which
      # check refused — a cross-row predicate no CAS on `role` can carry.
      with_lock do
        if owner?
          :owner_protected
        elsif removed?
          :not_active
        elsif role == target_role
          :role_changed
        elsif target_role == "member" && last_active_admin?
          :last_admin
        else
          update!(role: target_role)
          :role_changed
        end
      end
    end
  end
end
