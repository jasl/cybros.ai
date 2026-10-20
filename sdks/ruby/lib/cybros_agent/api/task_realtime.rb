module CybrosAgent
  module Api
    # A projection of the original task's permission to exchange live data.
    # max_age_ms starts at the request's send time, never its receive time.
    TaskRealtime = Data.define(:status, :reason, :connection_id, :offer_sdp, :answer_sdp, :max_age_ms) do
      def active? = status == "active"
      def closed? = status == "closed"
    end

    module TaskRealtimeProjections
      include Parsing

      SHAPES = {
        TaskRealtime => {
          status: :string, reason: :optional_string, connection_id: :optional_string,
          offer_sdp: :optional_string, answer_sdp: :optional_string, max_age_ms: :integer,
        },
      }.freeze
    end
  end
end
