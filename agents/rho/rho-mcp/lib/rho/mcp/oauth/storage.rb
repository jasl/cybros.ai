require "set"
require "time"
require_relative "../errors"

module Rho
  module Mcp
    module Oauth
      # The credential file cannot be read: wrong mode, wrong owner,
      # corrupt. Its message is the core sentence both surfaces extend
      # (`down:` adds "— rho refuses to read it", the call's refusal "— ask
      # the person to chmod it"); never spelled "needs login".
      class CredentialFile < Rho::Mcp::Error; end

      # THE STORE: the gem's four-method storage
      # contract over ONE `Rho::StateFile` per server —
      # `<RHO_HOME>/mcp/credentials/<key>.json`, 0600 under 0700, owner-
      # checked, crash-safe temp + rename, the vault's own class. Per server
      # because the StateFile lock is in-process and `rho mcp login` runs
      # beside a daemon: the daemon's refresh of one server and the CLI's
      # login of another touch different files.
      #
      # The document: `url` (the row's at login — on a mismatch `tokens`
      # ANSWERS NIL, the one guard against sending tokens minted for one
      # URL to another), `client_information` and `tokens` (the gem's two
      # hashes, VERBATIM, its `issuer` stamps inside), `issued_at` (the ONE
      # stamp, written at every `save_tokens` — a login and a refresh alike;
      # its one use is the probe's "past its time" sentence, never a send
      # decision), `pending_scope` (the step-up union the daemon's headless
      # validator recorded, cleared by the verb).
      #
      # Every gem method READS THE FILE (a login lands in a running daemon
      # without a boot; one stat + parse per request) and WRITES under the
      # file's lock. `read` is the ONE parse boundary: the two object
      # members are Hash-or-absent from there on (a hand edit is the sole
      # way a non-object appears), and every reader tests nil. A
      # pre-registered `oauth.client_id` OVERLAYS in memory: the file holds
      # only the gem's issuer stamp for such a row, so parse stays pure and
      # nothing configured is copied to disk. `save_tokens(nil)` — the
      # gem's `clear_tokens!` — keeps the registration (the gem's own
      # storage contract). A `PublishedError` keeps the new pair in memory
      # for the life of this process, logs once, never retries.
      #
      # `secret_values` is the IN-MEMORY set of every access and refresh
      # token this process read or saved — accumulated, never dropped (an
      # old error message may quote a rotated value) — the redactor's live
      # source; it never reads the file.
      #
      # `optional` is THE OPTIONAL-AUTHORIZATION MARK: the verb records,
      # after the flow saved the pair, that the login went through
      # `Challenge.published` — the server answered anonymously too, and
      # the token is an addition, never the door — so the `auth:` line
      # can say so. Kept through a refresh (`save_tokens` merges), dropped
      # with the tokens, re-learned by the next login.
      class Storage
        Status = Data.define(:state, :reason, :issuer, :scope, :issued_at, :refresh_token, :optional) do
          def initialize(optional: false, **members) = super

          def logged_in? = state == :logged_in
        end

        TOKEN_KEYS = %w[access_token refresh_token].freeze
        OBJECT_KEYS = %w[tokens client_information].freeze
        STAMP_KEY = "issuer".freeze
        OPTIONAL_KEY = "optional".freeze
        REFUSAL = "this verb does not write credentials".freeze

        attr_reader :row, :file

        def initialize(file:, row:, log: nil, clock: -> { Time.now })
          @file = file
          @row = row
          @log = log
          @clock = clock
          @seen = Set.new
          @unflushed = nil
          @unflushed_logged = false
        end

        def read_only? = false

        # ---- the gem's four ----

        def tokens
          document = read
          tokens = document&.dig("tokens")
          return nil if tokens.nil? || document["url"] != @row.url

          remember(tokens)
          tokens
        end

        def save_tokens(tokens)
          remember(tokens) unless tokens.nil?
          update do |document|
            if tokens.nil?
              document.except("tokens", "issued_at", OPTIONAL_KEY)
            else
              document.merge("url" => @row.url, "tokens" => tokens, "issued_at" => @clock.call.utc.iso8601)
            end
          end
          @log&.info("mcp.oauth.refreshed", server: @row.key) unless tokens.nil?
          tokens
        end

        def client_information
          stored = read&.dig("client_information")
          configured = @row.oauth&.client_id
          return stored if configured.nil?

          { "client_id" => configured, "token_endpoint_auth_method" => "none" }.merge((stored || {}).slice(STAMP_KEY))
        end

        def save_client_information(info)
          update do |document|
            if info.nil?
              document.except("client_information")
            elsif @row.oauth&.client_id
              document.merge("client_information" => info.to_h.transform_keys(&:to_s).slice(STAMP_KEY))
            else
              document.merge("client_information" => info)
            end
          end
          info
        end

        # ---- ours ----

        # Read-only, no network: the `auth:` line, the probe, the verb.
        def status
          document = read
          tokens = document&.dig("tokens")
          return Status.new(state: :needs_login, reason: "no tokens", issuer: nil, scope: nil, issued_at: nil, refresh_token: false) if tokens.nil?
          unless document["url"] == @row.url
            return Status.new(state: :needs_login, reason: "logged in for #{document["url"]}, the row now names #{@row.url}",
              issuer: nil, scope: nil, issued_at: nil, refresh_token: false)
          end
          if (pending = document["pending_scope"])
            required = (pending.to_s.split - tokens["scope"].to_s.split).join(" ")
            return Status.new(state: :needs_login, reason: "the server now requires scope #{required}; the login asks for #{pending}",
              issuer: nil, scope: nil, issued_at: nil, refresh_token: false)
          end

          Status.new(state: :logged_in, reason: nil, issuer: tokens["issuer"], scope: tokens["scope"],
            issued_at: document["issued_at"], refresh_token: !tokens["refresh_token"].to_s.empty?,
            optional: document[OPTIONAL_KEY] == true)
        rescue CredentialFile => error
          Status.new(state: :credential_file, reason: error.message, issuer: nil, scope: nil, issued_at: nil, refresh_token: false)
        end

        # The optional-authorization mark, written by the verb after the
        # flow saved the pair; `false` drops it.
        def record_optional(optional)
          update { |document| optional ? document.merge(OPTIONAL_KEY => true) : document.except(OPTIONAL_KEY) }
        end

        def pending_scope
          value = read&.dig("pending_scope")
          value.to_s.empty? ? nil : value
        end

        def record_pending_scope(scopes)
          update { |document| document.merge("pending_scope" => Array(scopes).join(" ")) }
        end

        def clear_pending_scope!
          update { |document| document.except("pending_scope") }
        end

        # The tokens as stored, for the sentences that name a clock; nil
        # past the URL rule.
        def issued_at
          value = read&.dig("issued_at")
          value.nil? ? nil : Time.iso8601(value.to_s)
        rescue ArgumentError
          nil
        end

        def secret_values = @seen.to_a.freeze

        def read_only = ReadOnly.new(self)

        # Logout: the file gone whole — tokens AND registration.
        def delete!
          @unflushed = nil
          @file.delete
          nil
        end

        # `mcp/credentials/<key>.json`, the spelling every sentence uses.
        def relative_path = File.join("mcp", "credentials", "#{@row.key}.json")

        private

          def remember(tokens)
            TOKEN_KEYS.each do |name|
              value = tokens[name]
              @seen << value.to_s unless value.to_s.empty?
            end
          end

          # The document, or nil for no file; the in-memory pair after a
          # `PublishedError`; a file rho refuses to read is `CredentialFile`.
          # A non-object under an object key is dropped here, once.
          def read
            normalize(@unflushed || @file.read)
          rescue Rho::StateError => error
            raise CredentialFile, credential_sentence(error)
          end

          def normalize(document)
            document&.reject { |key, value| OBJECT_KEYS.include?(key) && Hash.try_convert(value).nil? }
          end

          def update
            @file.with_lock do
              document = yield(read || {})
              begin
                @file.write(document)
                @unflushed = nil
              rescue Rho::StateFile::PublishedError
                @unflushed = document
                @log&.warn("mcp.oauth.store_unflushed", server: @row.key) unless @unflushed_logged
                @unflushed_logged = true
              end
            end
          rescue Rho::StateError => error
            raise CredentialFile, credential_sentence(error)
          end

          # rho's own words, the file named by its place under the home.
          def credential_sentence(error)
            reason = error.message.sub(/\Astate file \S+ /, "").sub("must be private to its owner", "must be private")
            "credential file #{relative_path} #{reason}"
          end
      end

      # THE READ-ONLY VIEW: the access token alone (no `refresh_token`, so
      # the gem never refreshes; `clear_tokens!` is only the refresh's
      # `invalid_grant` arm, so it never clears), the client information
      # as above, and a refusal from either save — the probe's and the
      # login proof's storage, on which nothing is spent and nothing is
      # written.
      class ReadOnly
        def initialize(storage)
          @storage = storage
        end

        def read_only? = true

        def row = @storage.row

        def tokens = @storage.tokens&.except("refresh_token")

        def client_information = @storage.client_information

        def save_tokens(_tokens) = raise(Rho::Mcp::Error, Storage::REFUSAL)

        def save_client_information(_info) = raise(Rho::Mcp::Error, Storage::REFUSAL)

        def status = @storage.status

        def pending_scope = @storage.pending_scope

        # A step-up seen through the view records nothing — the no-op, never
        # a raise: the headless validator must answer false so the gem
        # raises its own refusal and the connection classifies it.
        def record_pending_scope(_scopes) = nil

        def issued_at = @storage.issued_at

        def secret_values = @storage.secret_values

        def relative_path = @storage.relative_path

        def read_only = self
      end
    end
  end
end
