require "cybros_agent"

module Rho
  class Runner
    # REDACTION BY VALUE (shared by MCP and ACP clients). `CybrosAgent::Redaction` knows
    # Nexus's own credential families (`sk-`, `rt-`, …) and nothing else: a `FX_TOKEN`
    # value, a `ghp_…`, a bearer echoed by a child's stderr would ride through it untouched.
    # A protocol table's parser holds the exact expanded value of every `${NAME}` and every
    # header (`Secrets`), so every occurrence of each is replaced with `•••` — longest
    # first, so a value that contains another is erased whole — on the stderr tail, every
    # transport error message, the failure sentences, the notice lines, every log line and a
    # probe's output — and on the MODEL-READ SURFACE: a result's text and structure, a
    # document's body, a delegation's progress lines and capture, before they leave the
    # extension; the SDK's family redaction rides on top. Values under 8 bytes are not
    # redacted: a `•••` for every `1` would erase the text it was protecting.
    #
    # THE LIVE SET: an OAuth row's tokens rotate
    # at every refresh, so beside the static set frozen at construction a
    # `live:` source — anything answering `secret_values`, the in-memory
    # set of every token it read or saved in this process, rotated ones
    # kept — is read at every call; the two sets are erased together,
    # longest first. The redactor never touches a credential file.
    #
    # THE VALUE SET ALONE (`secrets_only`): a text a PERSON must use verbatim — the authorization URL
    # `rho mcp login` prints, whose random `state` and `code_challenge`
    # are free to spell `sk-`-like bytes the authorization server will
    # check — is erased of the two sets' values and never of the SDK's
    # families; `call` is that plus the families, for everything else.
    class Redact
      MASK = "•••".freeze
      MIN_BYTES = 8

      attr_reader :secrets

      def initialize(secrets = [], live: nil)
        @secrets = Array(secrets).map(&:to_s).reject { |value| value.bytesize < MIN_BYTES }
          .uniq.sort_by { |value| -value.bytesize }.freeze
        @live = live
      end

      def call(text)
        CybrosAgent::Redaction.call(secrets_only(text))
      end

      def secrets_only(text)
        current.reduce(text.to_s) { |acc, secret| acc.gsub(secret, MASK) }
      end

      # A JSON value walked: every string in it — keys included, a secret
      # under a key is a secret — through `call`; the numbers, booleans
      # and nils are not text and pass. The walk, never a re-serialization:
      # a secret that JSON would escape (`"`, `\`) is not found in its
      # escaped spelling.
      def structure(value)
        case value
        when Hash then value.to_h { |key, item| [key.is_a?(String) ? call(key) : key, structure(item)] }
        when Array then value.map { |item| structure(item) }
        when String then call(value)
        else value
        end
      end

      # Every value of a hash masked, the keys kept: how a verb prints an
      # `env` or a `headers` table — names only, never a value.
      def self.masked(table)
        table.to_h { |key, _value| [key.to_s, MASK] }
      end

      private

        # The static set with the live one folded in, longest first across
        # both, the floor applied to each.
        def current
          return @secrets if @live.nil?

          live = @live.secret_values.map(&:to_s).reject { |value| value.bytesize < MIN_BYTES }
          return @secrets if live.empty?

          (@secrets + live).uniq.sort_by { |value| -value.bytesize }
        end
    end
  end
end
