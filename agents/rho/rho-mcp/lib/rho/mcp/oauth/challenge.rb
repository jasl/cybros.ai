require "faraday"
require "json"
require "mcp"

module Rho
  module Mcp
    module Oauth
      # THE NO-TOKEN 401, CLASSIFIED WITHOUT A NETWORK: a server nobody logged in to answers the gem's
      # `RequestHandlerError` (`error_type: :unauthorized`; under
      # `connect(mode: :auto)` the legacy `initialize`'s, both carrying the
      # challenge), and its `WWW-Authenticate` — parsed by the gem's own
      # parser — says which door the row wants. A Bearer challenge WITH
      # `resource_metadata` (the spec's first discovery mechanism) is a
      # login; one WITHOUT it is a header-wanting server or a well-known-
      # only OAuth server, so both doors are named; no Bearer challenge is
      # a header. The daemon reads no third-party host for an unlogged row
      # — the verb runs the gem's full discovery.
      #
      # THE OPTIONAL-AUTHORIZATION SHAPE (the spec's "authorization is
      # OPTIONAL"; `authorization-server-discovery.mdx`'s second mechanism)
      # is the VERB'S probe alone (`published`): a server that answered the
      # anonymous initialize classifies nothing, but may still publish an
      # authorization server — the `WWW-Authenticate` hint a GET on the MCP
      # URL carries, then RFC 9728's well-known document path-aware first
      # and at the root second. A published document naming an
      # authorization server is an `:oauth` challenge marked `optional`,
      # its `resource_metadata` the URL the document was read at (the
      # flow reads the same one) and its `scope` the GET's, if named; a
      # server publishing nothing answers nil — nothing to log in to.
      class Challenge
        # The gem's own locate of a Bearer challenge (`parse_www_authenticate`
        # answers `{}` for a bare `Bearer` and for no challenge alike).
        BEARER = /(?:\A|,)\s*Bearer(?:\s|\z)/i
        # A protected-resource document is small; a body past this is not one.
        MAX_DOCUMENT_BYTES = 65_536

        attr_reader :kind, :params

        def initialize(kind:, params:, optional: false)
          @kind = kind
          @params = params
          @optional = optional
        end

        def self.unauthorized?(error)
          error.is_a?(MCP::Client::RequestHandlerError) && error.error_type == :unauthorized
        end

        # The three kinds, from the header alone.
        def self.classify(error)
          header = www_authenticate(error)
          params = MCP::Client::OAuth::Discovery.parse_www_authenticate(header)
          kind = if !header.to_s.match?(BEARER) then :header
          elsif params["resource_metadata"] then :oauth
          else :bearer
          end
          new(kind: kind, params: params.freeze)
        end

        # What Faraday saw, when the gem wrapped it.
        def self.www_authenticate(error)
          headers = error.original_error&.response&.dig(:headers)
          return nil if headers.nil?

          headers["www-authenticate"] || headers["WWW-Authenticate"]
        end

        # The probe of a server that answered anonymously: the row's
        # headers ride (the transport's are the same), every request is
        # bounded by `seconds`, a network fault or an unparsable body reads
        # as nothing published.
        def self.published(url:, headers: {}, seconds:)
          client = Faraday.new(headers: headers.merge("Accept" => "application/json")) do |faraday|
            faraday.options.open_timeout = seconds
            faraday.options.timeout = seconds
          end
          hint = MCP::Client::OAuth::Discovery.parse_www_authenticate(fetch(client, url)&.headers&.[]("www-authenticate"))
          candidates = MCP::Client::OAuth::Discovery.protected_resource_metadata_urls(server_url: url,
            resource_metadata_url: hint["resource_metadata"])
          found = candidates.find { |candidate| protected_resource_document?(fetch(client, candidate)) }
          return nil if found.nil?

          new(kind: :oauth, params: { "resource_metadata" => found, "scope" => hint["scope"] }.compact.freeze, optional: true)
        end

        def self.fetch(client, url)
          client.get(url)
        rescue Faraday::Error
          nil
        end

        # A 2xx JSON object naming at least one authorization server.
        def self.protected_resource_document?(response)
          return false if response.nil? || !response.success? || response.body.to_s.bytesize > MAX_DOCUMENT_BYTES

          document = JSON.parse(response.body.to_s)
          servers = document.is_a?(Hash) ? document["authorization_servers"] : nil
          servers.is_a?(Array) && servers.any? { |server| server.is_a?(String) && !server.empty? }
        rescue JSON::ParserError
          false
        end

        def oauth? = kind == :oauth
        def bearer? = kind == :bearer
        def header? = kind == :header
        # Published, never challenged: the server answers anonymously too.
        def optional? = @optional

        def resource_metadata = params["resource_metadata"]
        def scope = params["scope"]

        # The row's `down:` sentence; `home:` false on a host with no rho
        # home to hold a login.
        def sentence(key, home: true)
          case kind
          when :oauth
            if home
              "needs login — run `rho mcp login #{key}`"
            else
              "needs login, and this host has no rho home to hold one — declare the server on a rho home"
            end
          when :bearer
            "unauthorized (401 with a Bearer challenge naming no OAuth metadata) — a `headers` bearer, or " \
              "`rho mcp login #{key}` if it speaks OAuth"
          else
            "unauthorized (401 without a Bearer challenge) — the server wants a header"
          end
        end
      end
    end
  end
end
