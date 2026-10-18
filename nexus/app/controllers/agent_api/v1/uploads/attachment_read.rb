module AgentAPI::V1::Uploads::AttachmentRead
  extend ActiveSupport::Concern
  include ::AttachmentRead

  included do
    serves_plane :member
  end

  private

    def acting_user = current_credential.user
end
