module AgentAPI::RealtimeSignaling
  extend ActiveSupport::Concern

  included do
    prepend_before_action :no_store
  end

  private

    def signal_parameters
      id = params.require(:connection_id).to_s
      raise APIErrors::ParameterInvalid, :connection_id unless Tasks::ToolTask::RealtimeSignal::CONNECTION_ID.match?(id)

      sdp = Tasks::ToolTask::RealtimeSignal.description(params.require(:sdp))
      { connection_id: id, sdp: sdp }
    rescue ArgumentError
      raise APIErrors::ParameterInvalid, :sdp
    end

    def render_signal_outcome(outcome, realtime)
      if outcome == :accepted
        render json: { realtime: realtime.projection }
      else
        render_error(outcome, "Refused: #{outcome}", status: outcome == :not_authorized ? :forbidden : :conflict)
      end
    end

    # Separate from claims and ordinary member reads; two reads/second per
    # attached task fit a bounded 20-task credential budget with headroom.
    def caller_rate_limit = 3000

    def rate_limit_identity = "#{super}/realtime/#{action_name}"
end
