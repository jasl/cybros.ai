# Pages carrying a raw capability must not survive the HTTP cache or Turbo's
# snapshot, nor leak their URL via Referer; prepended so early exits (rate
# limits, invalid-capability redirects) get the same headers.
module CapabilityPageResponse
  extend ActiveSupport::Concern

  included do
    prepend_before_action :protect_capability_page_response
  end

  private

    def protect_capability_page_response
      no_store
      response.headers["Referrer-Policy"] = "no-referrer"
      @capability_page_response = true
    end
end
