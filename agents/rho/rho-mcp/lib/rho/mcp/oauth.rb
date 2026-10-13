require "mcp"
require_relative "oauth/storage"
require_relative "oauth/challenge"
require_relative "oauth/provider"
require_relative "oauth/callback"
require_relative "oauth/login"

module Rho
  module Mcp
    # MCP OAUTH. An OAuth-protected
    # streamable-HTTP server is connected by the official gem's own
    # authorization-code + PKCE flow — its discovery, its PKCE, its
    # challenge parser, its refresh, its step-up — driven ONCE by a person
    # through `rho mcp login SERVER` (a browser, a loopback callback in the
    # CLI process), its tokens kept ONE PRIVATE FILE PER SERVER under rho's
    # home and read by the daemon's transport as the `Authorization`
    # header: refreshed by the gem on a 401, never printed, never logged,
    # and refused — never re-registered, never browsed — by a daemon that
    # has no person to ask. rho-mcp writes what the gem leaves to the
    # embedder: the STORAGE (`Storage`), the two INTERACTIONS on one
    # provider class (`Provider.headless`, `Provider.interactive`), the
    # CLASSIFIER of a no-token 401 (`Challenge`), the LISTENER
    # (`Callback`) and the VERBS (`Login`, `Logout`).
    module Oauth
      module_function

      # The storage a row's credentials live in, or nil where this process
      # has no home to hold one: the base handle, a standalone runner — a
      # host that reaches `Rho::StateFile` only where rho is loaded, as
      # `Commands.refuse` reaches `Rho::Error`.
      def storage_for(row, home:, log: nil, clock: -> { Time.now })
        return nil unless row.oauth? && defined?(Rho::StateFile) && home.respond_to?(:mcp_credentials_dir)

        Storage.new(file: Rho::StateFile.new(File.join(home.mcp_credentials_dir, "#{row.key}.json")), row: row,
          log: log, clock: clock)
      end
    end
  end
end
