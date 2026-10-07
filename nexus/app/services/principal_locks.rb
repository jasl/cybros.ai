# The within-table order the ladder cannot see: Agent principals before
# Humans, since an Agent's authority derives from its steward, then
# ascending id. Every multi-user writer descends it from here.
module PrincipalLocks
  # Every principal this transaction will touch, in any order and with
  # duplicates: the helper is what puts them in THE order. `lock!` reloads in
  # place, so an authority recheck after this call reads locked rows.
  def self.descend(*principals)
    users = principals.flatten.compact.uniq
    users.select(&:agent_member?).sort_by(&:id).each(&:lock!)
    users.select(&:human?).sort_by(&:id).each(&:lock!)
  end
end
