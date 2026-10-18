module UsageAnalysisParameters
  extend ActiveSupport::Concern
  include ReportWindowParameters

  private

    def analysis_options
      # Analysis reads exact windows without a time-series unit.
      raise APIErrors::ParameterInvalid, :unit if params.key?(:unit)

      values = params.permit(:group_by, :rank_by, :limit)
      %w[group_by rank_by limit].each do |field|
        raise APIErrors::ParameterInvalid, field if params.key?(field) && values[field].nil?
      end
      group_by = values[:group_by]&.to_s || "provider_id"
      rank_by = values[:rank_by]&.to_s || "request_count"
      raise APIErrors::ParameterInvalid, :group_by unless ModelUsageRollups::Analysis::GROUPS.include?(group_by)
      raise APIErrors::ParameterInvalid, :rank_by unless ModelUsageRollups::Analysis::RANKS.include?(rank_by)

      {
        group_by:, rank_by:,
        limit: limit_param(default: ModelUsageRollups::Analysis::DEFAULT_LIMIT,
          max: ModelUsageRollups::Analysis::MAX_LIMIT, value: values[:limit]),
      }
    end

    def analysis_filters
      values = params.permit(*ModelUsageRollups::Analysis::GROUPS)
      # A named model dimension must stay a scalar; dropping it would widen
      # the caller's requested receipt set. Blank scalar choices mean All.
      ModelUsageRollups::Analysis::GROUPS.each do |field|
        raise APIErrors::ParameterInvalid, field if params.key?(field) && values[field].nil?
      end
      values.to_h.transform_values(&:to_s).reject { |_key, value| value.empty? }
    end

    # Administration cannot silently widen a rejected member/activity selector
    # into Account totals. This is the existing admin report's strict contract.
    def admin_analysis_filters
      known = ModelUsageRollups::Analysis::GROUPS + %w[from to group_by rank_by limit]
      unsupported = request.query_parameters.keys - known
      analysis_filters.merge(unsupported.index_with(nil))
    end

    def selected_analysis_agent
      if params[:agent_public_id].present?
        current_account.users.where(kind: :agent).find_by!(public_id: params.expect(:agent_public_id).to_s)
      end
    end
end
