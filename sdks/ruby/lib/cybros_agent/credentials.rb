module CybrosAgent
  # The client-side home for credential policy. One connection's
  # credentials, their durable form, and the rules that keep a rotating
  # single-use refresh token from ever being presented twice.
  module Credentials
  end
end

require_relative "credentials/errors"
require_relative "credentials/store"
require_relative "credentials/oauth"
