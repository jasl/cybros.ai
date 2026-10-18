# A body's liveness reference to one uploaded blob.
class ContentBodyUpload < ApplicationRecord
  belongs_to :content_body, inverse_of: :content_body_uploads
  belongs_to :content_upload
end
