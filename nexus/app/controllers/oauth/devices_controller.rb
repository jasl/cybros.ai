# GET /oauth/device — the code-entry page (the wire-stable
# verification_uri). verification_uri_complete only prefills the code.
class OAuth::DevicesController < OAuth::BrowserController
  def show
    @prefilled_code = params[:user_code].to_s.first(16)
    @return_to = request.fullpath
  end
end
