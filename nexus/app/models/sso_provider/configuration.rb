# The candidate shares the provider's field types. Unpublished credentials stay
# together inside one encrypted attribute until the browser test succeeds.
class SsoProvider::Configuration
  include StoreModel::Model

  %i[client_id client_secret authorization_endpoint token_endpoint userinfo_endpoint
    trusted_origins scopes token_auth_method subject_field email_field
    email_verified_field name_field required_group].each do |name|
    attribute name, :string
  end
  attribute :jit, :boolean
end
