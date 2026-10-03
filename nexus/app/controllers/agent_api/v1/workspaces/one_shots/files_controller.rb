# The bytes a non-text workload produced, proxied never redirected (a signed
# blob URL is a global bearer token), addressed by ordinal (attachments carry
# no public id), served through the framework's own `ActiveStorage::Streaming`
# — a `Range` answers 206 and the slice, a whole read carries `Accept-Ranges`
# — on whichever storage service the deployment configured (rank 4 of the
# Rails-native review: the `:nodoc:` Disk-only file server is gone, and the
# Disk pin with it). `Streaming` runs the body on a live thread; `Current`
# carries into it under the fiber isolation level.
class AgentAPI::V1::Workspaces::OneShots::FilesController <
      AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::V1::WorkspaceScoped

  include ActiveStorage::Streaming

  def show
    one_shot = OneShot.where(workspace_id: @workspace.id).listable
      .find_by!(public_id: params.fetch(:one_shot_public_id))
    attachment = AgentAPI::OneShotPresenter.output_files(one_shot)[index]
    raise ActiveRecord::RecordNotFound if attachment.nil?

    blob = attachment.blob
    if request.headers["Range"].present?
      send_blob_byte_range_data blob, request.headers["Range"], disposition: "attachment"
    else
      response.headers["Accept-Ranges"] = "bytes"
      response.headers["Content-Length"] = blob.byte_size.to_s
      send_blob_stream blob, disposition: "attachment"
    end
  end

  private

    def index
      bounded_integer(params.fetch(:index), :index, range: 0..)
    end
end
