# The OAuth authorization-server namespace (`/oauth` routes resolve here via
# the registered OAuth inflection). Application and connector grants share
# binding, refresh rotation and revocation owners.
module OAuth
  DEVICE_GRANT_TYPE = "urn:ietf:params:oauth:grant-type:device_code".freeze
  CODE_GRANT_TYPE = "authorization_code".freeze
  APPLICATION_CLIENT_ID = "cybros-application".freeze
  APPLICATION_SCOPE = "application".freeze
  REFRESH_GRANT_TYPE = "refresh_token".freeze

  # The well-known first-party device-flow client id: a public, non-secret,
  # same-across-deployments value identifying the first-party device-flow
  # client.
  DEVICE_CLIENT_ID = "cybros-first-party-connector".freeze

  # Raised by machine endpoints for malformed transport shapes; rendered as
  # the top-level invalid_request envelope.
  InvalidRequest = Class.new(StandardError)
end
