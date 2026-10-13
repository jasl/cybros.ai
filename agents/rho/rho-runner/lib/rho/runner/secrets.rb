module Rho
  class Runner
    # THE ROW-SECRETS RULE, one for every protocol table the person writes
    # into `settings.json` — rho-mcp's `mcp_servers`, the ACP client's
    # `acp_agents` — because a row that launches
    # a third party's process with a credential is the same object under
    # either protocol, and two copies of one rule drift.
    #
    # `${NAME}` in a row's value is expanded ONCE from the daemon's
    # environment — the door that keeps a token out of the file — and every
    # expansion is a secret. An unset name is that row's fault, raised by
    # the VARIABLE's name so the parser's sentence can name the key and
    # never a value. A LITERAL typed under a credential-shaped key
    # (`OPENAI_API_KEY: "sk-…"`) is a secret too, when it is long enough to be one (`Redact::MIN_BYTES`): a
    # shorter value is a flag or a port, and masking it would erase the
    # text it was protecting. What a secret then means is `Redact`'s.
    module Secrets
      EXPANSION = /\$\{([A-Za-z_][A-Za-z0-9_]*)\}/
      CREDENTIAL_SHAPED = /(KEY|PASSWORD|PASSWD|SECRET|TOKEN|CREDENTIAL)/i

      # A `${NAME}` no environment answers: `variable` is the name, and
      # the message names it too — never the surrounding value.
      class Unset < Error
        attr_reader :variable

        def initialize(variable)
          @variable = variable
          super("${#{variable}} is not set in the daemon's environment")
        end
      end

      module_function

      # The value with every `${NAME}` replaced, and the expanded values in
      # order of appearance — the row's secrets (a value read back from the
      # environment is one whatever its name). An empty variable is unset,
      # as `Config` reads one.
      def expand(value, env)
        secrets = []
        expanded = value.gsub(EXPANSION) do
          variable = Regexp.last_match(1)
          found = env[variable]
          raise Unset, variable if found.nil? || found.empty?

          secrets << found
          found
        end
        [expanded, secrets]
      end

      def literal_credential?(name, value)
        name.to_s.match?(CREDENTIAL_SHAPED) && value.bytesize >= Redact::MIN_BYTES
      end
    end
  end
end
