require "rho/runner"

module Rho
  module AcpClient
    # THE ROW GRAMMAR of `settings.json#plugins.rho.acp-client.configuration.agents`:
    # one key per agent — the person's short word — each schema-resolved row
    # is judged for protocol readiness at LOAD, before any process.
    # Faults are PER ROW: a row this module cannot accept is a `Fault`
    # with its sentence, listed `down: config:` on `rho acp-agents` and
    # logged, contributing no agent to the tool; only a table that cannot
    # be read AS ROWS refuses the extension (`Malformed`).
    #
    # The secrets trio is the runner's (`Rho::Runner::Secrets`): `${NAME}`
    # in `env` values expanded ONCE from the daemon's
    # environment — an unset name is that row's fault, naming the KEY and
    # never a value — every expansion a secret, a literal under a
    # credential-shaped key a secret too; `Rho::Runner::Redact` erases
    # them from everything a model, a log or a capture reads.
    #
    # `permissions` ∈ allow|reject (default allow; the floor still
    # refuses the nine shapes and the protected roots). `timeout_ms` is
    # the ONE clock (default ten minutes, at most the runner's park
    # ceiling). `auth_method` names an agent-type method id of the child;
    # `model` a value set through `set_config_option` when the child
    # lists a `category: "model"` option. `description` is the person's
    # words for the roster AND the model's text: required, since the tool
    # invents no sentence in the agent's mouth. `enabled` is the switch:
    # absent is on; `rho acp-agents enable|disable NAME` write it.
    module Settings
      class Malformed < Rho::Runner::Extensions::RegistrationError; end

      KEYS = %w[command args env description permissions timeout_ms auth_method model enabled].freeze
      # The key rides the tool's schema as an enum and the verbs' lines:
      # lowercase alphanumerics and single hyphens, rho-mcp's grammar.
      KEY_FORMAT = /\A[a-z0-9](?:-?[a-z0-9])*\z/
      KEY_MAX_LENGTH = 32
      PERMISSIONS = %w[allow reject].freeze
      DEFAULT_PERMISSIONS = "allow".freeze
      DEFAULT_TIMEOUT_MS = 600_000
      ENABLED = "enabled".freeze

      Row = Data.define(:key, :command, :args, :env, :description, :permissions, :timeout_ms, :auth_method, :model,
        :secrets, :enabled) do
        def enabled? = enabled
        def allow? = permissions == "allow"
        def fault? = false
        # The launch line as the verbs print it (through the row's redaction).
        def launch = [command, *args].join(" ")
      end

      # A row this module could not accept, listed beside the rows it did:
      # every member a row answers, so no caller probes.
      Fault = Data.define(:key, :sentence) do
        def fault? = true
        # A fault is listed by its sentence whatever `enabled` said.
        def enabled? = true
        def launch = nil
        def env = {}
        def description = nil
        def timeout_ms = nil
        def permissions = nil
        def secrets = []
      end

      module_function

      # `table` is the opaque `plugins.rho.acp-client.configuration.agents` object; `env` the daemon's
      # environment. Answers Rows and Faults in the table's order; raises
      # `Malformed` for the table.
      def parse(table, env: ENV)
        rows = Hash.try_convert(table)
        raise Malformed, "ACP agents must be an object of objects" if rows.nil?

        rows.map do |key, raw|
          key = key.to_s
          unless key.match?(KEY_FORMAT) && key.length <= KEY_MAX_LENGTH
            raise Malformed, "ACP agents names #{key.inspect}; an agent key is lowercase letters, digits and " \
                             "single hyphens, at most #{KEY_MAX_LENGTH} characters"
          end
          raise Malformed, "ACP agents[#{key}] must be an object" if Hash.try_convert(raw).nil?

          parse_row(key, raw.to_h.transform_keys(&:to_s), env)
        end
      end

      class RowFault < StandardError; end
      private_constant :RowFault

      def parse_row(key, raw, env)
        build_row(key, raw, env)
      rescue RowFault => fault
        Fault.new(key: key, sentence: fault.message)
      end

      def build_row(key, raw, env)
        stranger = raw.keys.find { |name| !KEYS.include?(name) }
        fault!(key, "#{stranger.inspect} is not a key of an agent row (the keys: #{KEYS.join(", ")})") if stranger
        command = raw["command"]
        fault!(key, "a row needs a \"command\" (a string)") unless command.is_a?(String) && !command.empty?
        args = raw.fetch("args", [])
        fault!(key, "args must be an array of strings") unless args.is_a?(Array) && args.all?(String)
        description = raw["description"]
        unless description.is_a?(String) && !description.strip.empty?
          fault!(key, "a row needs a \"description\" (your words for the roster; the model reads it)")
        end
        secrets = []
        Row.new(
          key: key, command: command, args: args.freeze, env: expanded_env(key, raw.fetch("env", {}), env, secrets),
          description: description.strip.freeze, permissions: permissions(key, raw),
          timeout_ms: timeout(key, raw), auth_method: optional_string(key, raw, "auth_method"),
          model: optional_string(key, raw, "model"), secrets: secrets.uniq.freeze, enabled: enabled_member(key, raw)
        )
      end

      def permissions(key, raw)
        return DEFAULT_PERMISSIONS unless raw.key?("permissions")

        value = raw["permissions"]
        fault!(key, "permissions must be one of #{PERMISSIONS.join(", ")}, got #{value.inspect}") unless PERMISSIONS.include?(value)
        value
      end

      def timeout(key, raw)
        return DEFAULT_TIMEOUT_MS unless raw.key?("timeout_ms")

        value = raw["timeout_ms"]
        limit = Rho::Runner::Extensions::Tool::MAX_TIMEOUT_MS
        return value if value.is_a?(Integer) && value.positive? && value <= limit

        fault!(key, "timeout_ms must be a positive integer of milliseconds no greater than #{limit}, got #{value.inspect}")
      end

      # `auth_method` and `model`: absent or null is none; a string must
      # have words in it.
      def optional_string(key, raw, name)
        value = raw[name]
        return nil if value.nil?

        fault!(key, "#{name} must be a string") unless value.is_a?(String)
        fault!(key, "#{name} must be a non-empty string") if value.strip.empty?
        value
      end

      # The switch: absent is on; `true` or `false`; anything else the fault.
      def enabled_member(key, raw)
        return true unless raw.key?(ENABLED)

        value = raw[ENABLED]
        fault!(key, "#{ENABLED} must be true or false, got #{value.inspect}") unless [true, false].include?(value)
        value
      end

      def expanded_env(key, table, env, secrets)
        fault!(key, "env must be an object of strings") unless table.is_a?(Hash)
        table.to_h do |name, value|
          fault!(key, "env.#{name} must be a string") unless value.is_a?(String)
          expanded = expand(key, name, value, env, secrets)
          secrets << expanded if Rho::Runner::Secrets.literal_credential?(name, expanded)
          [name.to_s, expanded]
        end.freeze
      end

      # The runner's expansion; an unset name is this row's fault, the
      # sentence naming the key and the variable, never a value.
      def expand(key, name, value, env, secrets)
        expanded, found = Rho::Runner::Secrets.expand(value, env)
        secrets.concat(found)
        expanded
      rescue Rho::Runner::Secrets::Unset => unset
        fault!(key, "env.#{name} names ${#{unset.variable}}, which is not set in the daemon's environment")
      end

      def fault!(key, sentence)
        raise RowFault, "acp agent \"#{key}\": #{sentence}"
      end
    end
  end
end
