# HTML and member collections apply the same filters before pagination.
module RunListing
  private

    def filtered_runs(scope, default_kind: "", fixed_executor: nil)
      fields = params.permit(:status, :attention, :from, :to, :answering_user_public_id, :agent_public_id, :executor_public_id, :kind)
      statuses = fields[:status].to_s.split(",").map(&:strip).reject(&:empty?)
      raise APIErrors::ParameterInvalid, :status if (statuses - Run::STATUSES).any?
      scope = scope.where(status: statuses) if statuses.any?

      attention = fields[:attention].to_s
      unless attention.empty?
        raise APIErrors::ParameterInvalid, :attention unless attention == "any"
        scope = scope.where.not(attention_reason: nil)
      end

      from = run_filter_time(fields[:from], :from)
      to = run_filter_time(fields[:to], :to)
      raise APIErrors::ParameterInvalid, :to if from && to && from >= to
      scope = scope.where(created_at: from..) if from
      scope = scope.where(created_at: ...to) if to
      scope = scope.for_agent(fields[:agent_public_id].to_s) if fields[:agent_public_id].present?
      executor_public_id = fixed_executor&.public_id || fields[:executor_public_id].presence
      scope = scope.for_executor(executor_public_id.to_s) if executor_public_id

      if fields[:answering_user_public_id].present?
        scope = scope.joins(:turn).where(turns: {
          answering_user_id: User.where(public_id: fields[:answering_user_public_id]).select(:id),
        })
      end

      case fields[:kind].presence || default_kind
      when "", "all" then scope
      when "standalone" then scope.where(variant_id: nil)
      when "conversation" then scope.where.not(variant_id: nil)
      else raise APIErrors::ParameterInvalid, :kind
      end
    end

    def run_filter_time(value, name)
      return if value.blank?

      ActiveModel::Type::DateTime.new.cast(value) || raise(APIErrors::ParameterInvalid, name)
    end
end
