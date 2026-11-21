# The API description is public metadata and needs no account or credential.
class OpenapiController < ActionController::API
  def show
    render json: Nexus::Openapi.document
  end
end
