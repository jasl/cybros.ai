module CybrosAgent
  # The client-side home for credential policy. One connection's
  # credentials, their durable form, and the lifecycle of either rotating
  # OAuth credentials or independently revocable static API keys.
  module Credentials
    # Rehydrate either supported authentication kind through one storage door.
    def self.load(authority:, store:, clock: -> { Time.now })
      document = Document.read(store)
      return if document.nil?

      if document.authentication_kind == "oauth"
        OAuth.new(authority: authority, store: store, clock: clock, document: document)
      else
        APIKey.new(authority: authority, store: store, document: document)
      end
    end
  end
end

require_relative "credentials/errors"
require_relative "credentials/store"
require_relative "credentials/document"
require_relative "credentials/oauth"
require_relative "credentials/api_key"
