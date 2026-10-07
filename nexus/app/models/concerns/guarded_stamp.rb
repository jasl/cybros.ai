# One guarded UPDATE on this row: the loser of a concurrent race changes
# nothing, and the winner mirrors the stamp into memory so both contenders
# converge on the same persisted state without a row lock.
module GuardedStamp
  extend ActiveSupport::Concern

  private

    def stamp_if(guard, column, at:)
      if guard.where(id: id).touch_all(column, time: at).positive?
        self[column] = at
        self.updated_at = at
        clear_attribute_changes([column.to_s, "updated_at"])
      end
      self
    end
end
