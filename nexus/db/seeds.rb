# Import API keys for an existing installation, including production. Test
# seeds never read provider keys from the environment. A missing lane is
# enabled, while an existing disabled lane stays disabled.
require_relative "seeds/import_environment_credentials"

unless Rails.env.test?
  if account = Account.order(:id).first
    ModelProviders::ImportEnvironmentCredentials.call(account: account)
  end
end
