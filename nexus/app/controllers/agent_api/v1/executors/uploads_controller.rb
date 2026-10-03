# POST /agent_api/v1/executor/uploads — the executor plane's door into the
# ONE ingest: a CAPTURE this executor publishes — a screenshot, a file's
# bytes — staged as ITS OWN (`creating_executor`), named later by a
# `resource_link` block in a commit's `content`, and served back on the
# member plane's bytes read to a reader of the result that names it. No
# `show`: nothing on this plane reads a capture back; an upload nothing
# names is reclaimed after a day.
class AgentAPI::V1::Executors::UploadsController < AgentAPI::V1::Executors::BaseController
  include UploadIngest

  def create
    ingest_upload(account: current_executor.account, creator: current_executor)
  end
end
