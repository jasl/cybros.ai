# The InferenceRequest's mirror: the one events channel over the
# listable InferenceRequest, with no transcript feed — a InferenceRequest has no turns — and
# no progress feed: nothing an executor posts names a InferenceRequest as its host.
#
# NOT EVERY CONSUMER IS READING THE OUTPUT: `items: "lifecycle"` is for one
# that is not reading the output and only wants to know where the run got
# to — it receives `run_status` and `result` and nothing else, because the
# filtering happens at the broadcasting rather than here.
class AgentAPI::V1::InferenceRequestEventsChannel < AgentAPI::V1::EventsChannel
  FEEDS = {
    "events" => "events",
    "lifecycle" => "lifecycle",
  }.freeze

  private

    def find_host(workspace, _user)
      InferenceRequest.where(workspace_id: workspace.id).listable
        .find_by(public_id: params[:inference_request_id])
    end
end
