class Uploads::BytesController < Work::BaseController
  include AttachmentRead

  def show
    send_upload_bytes
  end
end
