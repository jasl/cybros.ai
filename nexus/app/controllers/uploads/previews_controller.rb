class Uploads::PreviewsController < Work::BaseController
  include AttachmentRead

  rate_limit to: 30, within: 1.minute, by: -> { acting_user.public_id }

  def show
    send_representation("preview")
  end
end
