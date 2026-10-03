require "mcp"
require "rho/runner"
require "uri"

module Rho
  module Mcp
    # THE ROW GRAMMAR of `settings.json`'s `mcp_servers`:
    # one key per server — the operator's short word, never the remote
    # `serverInfo.name` — each an object rho keeps opaque and this module
    # judges at LOAD, before any process. Faults are PER SERVER: a row this
    # module cannot accept is a `Fault` with its sentence, listed `down:
    # config:` on `rho mcp` and logged, contributing no tool — the loader's
    # "one factory's failure is its own" applied one level down, so a dev
    # box without `REMOTE_TOKEN` keeps its local servers. Only a table that
    # cannot be read AS ROWS refuses the extension (`Malformed`): not an
    # object of objects, or a key outside the grammar.
    #
    # `${NAME}` in `env` and `headers` values is expanded ONCE here from the
    # daemon's environment — the door that keeps a token out of the file;
    # an unset name is that row's fault, naming the KEY and never a value.
    # The row's `secrets`, which the runner's `Redact` erases from
    # everything a model or a log reads: every expansion, every header
    # value (headers can carry credentials), and a
    # LITERAL under a credential-shaped `env` key (`OPENAI_API_KEY: "sk-…"` typed into the file is still a secret). The rule is the runner's `Secrets`: one
    # for every protocol table, held by no parser. A row with any
    # header refuses plain `http://` off loopback for the same reason
    # (sec-5): its values are secrets whatever the header is called — the
    # ONE secure-URL predicate is the gem's (`Discovery.secure_url?`), so
    # the parse-time fault and the gem's factory-time refusal agree.
    #
    # `oauth` is an http row's optional
    # sub-object `{client_id, callback_port}`: it only TUNES a login —
    # a pre-registered public client, a fixed loopback port. No key opts a
    # server in: any http row on a secure URL with no `Authorization`
    # header is OAuth-capable (`Row#oauth?`), and a 401 with an OAuth
    # challenge is what asks for the login.
    #
    # `enabled` is THE SWITCH: absent is on — a row a person wrote is
    # wanted; `false` parks the row (listed with `rho mcp enable NAME`,
    # connected to never, announced never — the shipped example's default,
    # `Builtin`); `rho mcp enable NAME` / `disable NAME` write it into the
    # person's row. Not a boolean is the row's fault, and a parked row that
    # is broken still carries its sentence: a fault is listed by its
    # sentence whatever `enabled` says.
    #
    # THE EDITOR'S ROWS (`from_acp`): an ACP client's `session/new` carries `mcpServers`, and the
    # daemon's door hands the list to rho-mcp per conversation EXACTLY as
    # it received it — stdio `{name, command, args, env: [{name, value}]}`,
    # http `{type: "http", name, url, headers: [{name, value}]}`. Each
    # entry is translated into the boot grammar above and parsed by the
    # same `parse_row`: `serves: agent` (the editor's servers run beside
    # the editor, on the surface's agent slot), `tools: "*"` (the editor
    # curates, not the operator), the parks and the profiles the defaults,
    # the `secrets` built as the boot table's are (every header value; a
    # literal under a credential-shaped env key). Values are LITERAL — the
    # editor resolved them; `${NAME}` is settings.json's grammar alone. An
    # `sse` or `acp` entry is a `Fault` ROW ("transport sse unsupported"):
    # listed by `rho mcp`, every other row unaffected, so `session/new`
    # still answers. A MALFORMED entry — not an object, no `name`, no
    # `command`/`url`, a type outside the vocabulary, a member of the wrong
    # type, a name listed twice — raises `ArgumentError` with a sentence
    # naming the entry before anything connects: the daemon answers 400
    # `malformed`, the ACP surface -32602. A name is NOT held to
    # `KEY_FORMAT`: an editor names its servers freely, `Naming.tool` folds
    # any name into the provider's floor, and no document rides a
    # conversation row. The boot grammar's own faults (a URL that is not
    # http(s), a header over plain `http://` off loopback) stay ROW faults.
    module Settings
      class Malformed < Rho::Runner::Extensions::RegistrationError; end

      TRANSPORTS = %w[stdio http].freeze
      SERVES = %w[runner agent].freeze
      # The intersection of the two grammars the derived names must fit:
      # `mcp__<key>__<tool>` (the provider's) and `<key>-<document>` (the
      # kernel's skill grammar, lowercase alphanumerics and single hyphens).
      KEY_FORMAT = /\A[a-z0-9](?:-?[a-z0-9])*\z/
      KEY_MAX_LENGTH = 32
      KEYS = %w[transport command args env cwd url headers tools timeout_ms startup_timeout_ms serves
                effect_profiles oauth enabled].freeze
      ENABLED = "enabled".freeze
      OAUTH_KEYS = %w[client_id callback_port].freeze
      PORT_RANGE = (1..65_535)
      AUTHORIZATION_HEADER = "authorization".freeze
      DEFAULT_STARTUP_TIMEOUT_MS = 30_000
      # An http server's park, and Faraday's read timeout with it
      # (deepseek's `DEFAULT_TOOL_CALL_TIMEOUT_MS`); a stdio server's is the
      # kernel's default park unless the row names one.
      DEFAULT_HTTP_TIMEOUT_MS = 60_000
      ALL_TOOLS = "*".freeze
      # The ACP `mcpServers` vocabulary: `type` absent is stdio; the two
      # this gem does not speak are faulted rows, anything else malformed.
      ACP_TYPES = %w[stdio http sse acp].freeze
      ACP_UNSUPPORTED_TYPES = %w[sse acp].freeze

      # The two optional tunings of a login; nil members are the defaults
      # (rho registers itself dynamically; the loopback port is ephemeral).
      Oauth = Data.define(:client_id, :callback_port)

      Row = Data.define(:key, :transport, :command, :args, :env, :cwd, :url, :headers, :tools, :timeout_ms,
        :startup_timeout_ms, :serves, :effect_profiles, :secrets, :oauth, :enabled) do
        def initialize(oauth: nil, enabled: true, **members) = super

        def fault? = false
        def stdio? = transport == "stdio"
        def http? = transport == "http"
        def all_tools? = tools == ALL_TOOLS
        # The switch: a disabled row is listed, never connected, never announced.
        def enabled? = enabled

        def allows?(raw_name) = all_tools? || tools.include?(raw_name)

        # The launch line as `rho mcp` prints it.
        def launch = stdio? ? [command, *args].join(" ") : url

        # THE ONE secure-URL predicate — the gem's: https, or http on a
        # loopback host by the gem's own `loopback_host?`.
        def secure_url? = http? && MCP::Client::OAuth::Discovery.secure_url?(url)

        # The static-bearer door, whatever the operator's spelling of the
        # header name (`expanded_table` keeps it).
        def authorization_header? = headers.keys.any? { |name| name.downcase == AUTHORIZATION_HEADER }

        # OAuth-capable: an http row the gem's client would accept a
        # provider on, not already carrying a bearer of its own.
        def oauth? = secure_url? && !authorization_header?
      end

      # A row this module could not accept, listed beside the rows it did
      # (`rho mcp` prints it `down` with the sentence, `serves` and
      # `transport` kept where they parsed): it launches nothing, carries
      # no environment or headers, is no transport and no door, and
      # answers so — every member a row answers, so no caller probes.
      Fault = Data.define(:key, :transport, :serves, :sentence) do
        def launch = nil
        def env = {}
        def headers = {}
        def fault? = true
        def stdio? = false
        def http? = false
        def oauth? = false
        # A fault is listed by its sentence whatever `enabled` said.
        def enabled? = true
      end

      NO_TOOLS_SENTENCE = 'mcp server "%<key>s" names no tools — name the ones you want under "tools", or "*" to ' \
                          "take every one; `rho mcp probe %<key>s` prints what it would declare and the bytes".freeze

      module_function

      # `table` is `Config#mcp_servers` (already an object of objects) or
      # anything an operator wrote; `env` is the daemon's environment;
      # `home` is where a stdio server's `cwd` defaults. Answers Rows and
      # Faults in the table's order; raises `Malformed` for the table.
      def parse(table, env: ENV, home: Dir.pwd)
        rows = Hash.try_convert(table)
        raise Malformed, "mcp_servers must be an object of objects" if rows.nil?

        rows.map do |key, raw|
          key = key.to_s
          unless key.match?(KEY_FORMAT) && key.length <= KEY_MAX_LENGTH
            raise Malformed, "mcp_servers names #{key.inspect}; a server key is lowercase letters, digits and " \
                             "single hyphens, at most #{KEY_MAX_LENGTH} characters"
          end
          raise Malformed, "mcp_servers[#{key}] must be an object" if Hash.try_convert(raw).nil?

          parse_row(key, raw.to_h.transform_keys(&:to_s), env, home)
        end
      end

      # THE EDITOR'S LIST (the module comment): the rows in the list's
      # order, a `Fault` per unsupported transport, `ArgumentError` for a
      # malformed entry. `home` is where a stdio server's `cwd` lands, as
      # `parse` reads it.
      def from_acp(entries, home: Dir.pwd)
        list = Array.try_convert(entries)
        raise ArgumentError, "mcpServers must be an array of server entries" if list.nil?

        shaped = list.each_with_index.map { |raw, index| acp_entry(raw, index) }
        doubled = shaped.map { |entry| entry["name"] }.tally.find { |_name, count| count > 1 }
        raise ArgumentError, "mcpServers names #{doubled.first.inspect} twice" if doubled

        shaped.map { |entry| acp_row(entry, home) }
      end

      # One entry's SHAPE: an object with a string `name` and a `type` in
      # the vocabulary (absent is stdio); the transport's members typed —
      # every refusal a sentence naming the entry by index and name.
      def acp_entry(raw, index)
        entry = Hash.try_convert(raw)&.transform_keys(&:to_s)
        raise ArgumentError, "mcpServers[#{index}] must be an object" if entry.nil?

        name = entry["name"]
        raise ArgumentError, "mcpServers[#{index}] needs a \"name\" (a string)" unless name.is_a?(String) && !name.empty?

        type = entry.fetch("type", "stdio")
        unless ACP_TYPES.include?(type)
          malformed!(index, name, "type must be one of #{ACP_TYPES.join(", ")}, got #{type.inspect}")
        end
        entry.merge("type" => type, "index" => index)
      end

      # The entry as a BOOT-GRAMMAR row: `serves: agent`, `tools: "*"`, the
      # pair lists folded to tables, then `parse_row` — literal values.
      def acp_row(entry, home)
        name = entry["name"]
        if ACP_UNSUPPORTED_TYPES.include?(entry["type"])
          return Fault.new(key: name, transport: entry["type"], serves: "agent", sentence: "transport #{entry["type"]} unsupported")
        end

        raw = { "transport" => entry["type"], "serves" => "agent", "tools" => ALL_TOOLS }
        parse_row(name, raw.merge(acp_members(entry)), {}, home, literal: true)
      end

      def acp_members(entry)
        index, name = entry.values_at("index", "name")
        if entry["type"] == "stdio"
          command = entry["command"]
          malformed!(index, name, "a stdio server needs a \"command\" (a string)") unless command.is_a?(String) && !command.empty?
          args = entry.fetch("args", [])
          malformed!(index, name, "args must be an array of strings") unless args.is_a?(Array) && args.all?(String)
          { "command" => command, "args" => args, "env" => acp_pairs(entry, "env") }
        else
          url = entry["url"]
          malformed!(index, name, "an http server needs a \"url\" (a string)") unless url.is_a?(String) && !url.empty?
          { "url" => url, "headers" => acp_pairs(entry, "headers") }
        end
      end

      # `[{name, value}, …]` → `{name => value}`; absent is empty.
      def acp_pairs(entry, member)
        pairs = entry.fetch(member, [])
        shaped = pairs.is_a?(Array) && pairs.all? do |pair|
          table = Hash.try_convert(pair)
          table && table["name"].is_a?(String) && !table["name"].empty? && table["value"].is_a?(String)
        end
        malformed!(entry["index"], entry["name"], "#{member} must be an array of {name, value} pairs of strings") unless shaped

        pairs.to_h { |pair| [pair["name"], pair["value"]] }
      end

      def malformed!(index, name, sentence)
        raise ArgumentError, "mcpServers[#{index}] (#{name.inspect}): #{sentence}"
      end

      # `literal` takes every `env`/`headers` value as it stands (the
      # editor's rows); the boot table expands `${NAME}`.
      def parse_row(key, raw, env, home, literal: false)
        transport = raw["transport"].to_s
        serves = raw.key?("serves") ? raw["serves"].to_s : default_serves(transport)
        build_row(key, raw, transport, serves, env, home, literal)
      rescue RowFault => fault
        Fault.new(key: key, transport: (transport if TRANSPORTS.include?(transport)),
          serves: (serves if SERVES.include?(serves)), sentence: fault.message)
      end

      class RowFault < StandardError; end
      private_constant :RowFault

      def build_row(key, raw, transport, serves, env, home, literal)
        stranger = raw.keys.find { |name| !KEYS.include?(name) }
        fault!(key, "#{stranger.inspect} is not a key of a server row (the keys: #{KEYS.join(", ")})") if stranger
        unless TRANSPORTS.include?(transport)
          fault!(key, "transport must be one of #{TRANSPORTS.join(", ")}, got #{raw["transport"].inspect}")
        end
        fault!(key, "serves must be one of #{SERVES.join(", ")}, got #{raw["serves"].inspect}") unless SERVES.include?(serves)

        secrets = []
        expanded_env = expanded_table(key, raw.fetch("env", {}), "env", env, secrets, literal)
        headers = expanded_table(key, raw.fetch("headers", {}), "headers", env, secrets, literal)
        secrets.concat(headers.values)
        command, args, cwd = stdio_members(key, raw, transport, home)
        url = http_members(key, raw, transport, headers)
        tools = tool_list(key, raw)
        Row.new(
          key: key, transport: transport, command: command, args: args, env: expanded_env, cwd: cwd, url: url,
          headers: headers, tools: tools,
          timeout_ms: optional_timeout(key, raw, "timeout_ms", transport == "http" ? DEFAULT_HTTP_TIMEOUT_MS : nil),
          startup_timeout_ms: optional_timeout(key, raw, "startup_timeout_ms", DEFAULT_STARTUP_TIMEOUT_MS),
          serves: serves.to_sym, effect_profiles: profiles(key, raw), secrets: secrets.uniq.freeze,
          oauth: oauth_members(key, raw, transport, url, headers), enabled: enabled_member(key, raw)
        )
      end

      def default_serves(transport) = transport == "http" ? "agent" : "runner"

      # The switch: absent is on; `true` or `false`; anything else the fault.
      def enabled_member(key, raw)
        return true unless raw.key?(ENABLED)

        value = raw[ENABLED]
        fault!(key, "#{ENABLED} must be true or false, got #{value.inspect}") unless [true, false].include?(value)
        value
      end

      def stdio_members(key, raw, transport, home)
        return [nil, [], nil] unless transport == "stdio"

        command = raw["command"]
        fault!(key, "a stdio server needs a \"command\" (a string)") unless command.is_a?(String) && !command.empty?
        args = raw.fetch("args", [])
        fault!(key, "args must be an array of strings") unless args.is_a?(Array) && args.all?(String)
        cwd = raw.fetch("cwd", nil)
        fault!(key, "cwd must be a string") unless cwd.nil? || cwd.is_a?(String)
        [command, args.freeze, File.expand_path(cwd.to_s.empty? ? home : cwd)]
      end

      def http_members(key, raw, transport, headers)
        return nil unless transport == "http"

        url = raw["url"]
        fault!(key, "an http server needs a \"url\" (a string)") unless url.is_a?(String) && !url.empty?
        parsed = begin
          URI.parse(url)
        rescue URI::InvalidURIError
          fault!(key, "url #{url.inspect} is not a URL")
        end
        fault!(key, "url must be http:// or https://") unless %w[http https].include?(parsed.scheme.to_s)
        # Every header value is a secret, so ANY header over plain http://
        # off loopback is the refusal — named by the first header, never
        # judged by its name (a `${TOKEN}` under `Cookie` is no less one).
        header = headers.keys.first
        if header && !MCP::Client::OAuth::Discovery.secure_url?(url)
          fault!(key, "header #{header} carries a credential over plain http:// to #{parsed.host}; use https://, " \
                      "or a loopback host")
        end
        url
      end

      # THE FOUR FAULTS OF `oauth`, knowable without a process: the
      # object on a stdio row, beside a bearer header of any spelling, on
      # a URL the gem would refuse a provider on, and a member outside the
      # grammar or its range.
      def oauth_members(key, raw, transport, url, headers)
        return nil unless raw.key?("oauth")

        table = raw["oauth"]
        fault!(key, "oauth must be an object") unless table.is_a?(Hash)
        fault!(key, "oauth is an http server's; a stdio server reads its credentials from `env`") unless transport == "http"
        if headers.keys.any? { |name| name.downcase == AUTHORIZATION_HEADER }
          fault!(key, "either a bearer header or oauth, not both")
        end
        fault!(key, "oauth needs https://, or a loopback host") unless MCP::Client::OAuth::Discovery.secure_url?(url)
        stranger = table.keys.find { |name| !OAUTH_KEYS.include?(name.to_s) }
        fault!(key, "#{stranger.inspect} is not a key of oauth (the keys: #{OAUTH_KEYS.join(", ")})") if stranger
        table = table.transform_keys(&:to_s)
        client_id = table["client_id"]
        fault!(key, "oauth.client_id must be a string") unless client_id.nil? || (client_id.is_a?(String) && !client_id.empty?)
        port = table["callback_port"]
        unless port.nil? || (port.is_a?(Integer) && PORT_RANGE.cover?(port))
          fault!(key, "oauth.callback_port must be an integer from 1 to 65535, got #{port.inspect}")
        end
        Oauth.new(client_id: client_id, callback_port: port)
      end

      # REQUIRED: a list of raw names, or `"*"`. Absent is the refusal
      # without a spawn: the sentence names where the bytes are.
      def tool_list(key, raw)
        tools = raw["tools"]
        raise RowFault, format(NO_TOOLS_SENTENCE, key: key) if tools.nil?
        return ALL_TOOLS if tools == ALL_TOOLS
        unless tools.is_a?(Array) && !tools.empty? && tools.all? { |name| name.is_a?(String) && !name.empty? }
          fault!(key, "tools must be a non-empty list of the server's tool names, or \"*\"")
        end

        tools.uniq.freeze
      end

      def optional_timeout(key, raw, name, default)
        return default unless raw.key?(name)

        value = raw[name]
        limit = Rho::Runner::Extensions::Tool::MAX_TIMEOUT_MS
        return value if value.is_a?(Integer) && value.positive? && value <= limit

        fault!(key, "#{name} must be a positive integer of milliseconds no greater than #{limit}, got #{value.inspect}")
      end

      # The operator's act, judged by the runner's mirrored vocabulary
      # (`Tool.effect_profile_fault`) BEFORE any class is built, so a typo
      # is this row's sentence and never a blanked announcement.
      def profiles(key, raw)
        table = raw.fetch("effect_profiles", {})
        fault!(key, "effect_profiles must be an object of tool name to effect profile") unless table.is_a?(Hash)
        table.to_h do |name, profile|
          fault = Rho::Runner::Extensions::Tool.effect_profile_fault(profile)
          fault!(key, "effect_profiles.#{name} must be a full effect profile #{fault}") if fault
          [name.to_s, profile.to_h.transform_keys(&:to_s).freeze]
        end.freeze
      end

      def expanded_table(key, table, name, env, secrets, literal)
        fault!(key, "#{name} must be an object of strings") unless table.is_a?(Hash)
        table.to_h do |entry, value|
          fault!(key, "#{name}.#{entry} must be a string") unless value.is_a?(String)
          expanded = literal ? value : expand(key, value, name, entry, env, secrets)
          # A literal under a credential-shaped `env` key is a secret when
          # it is long enough to be one (the runner's rule).
          secrets << expanded if name == "env" && Rho::Runner::Secrets.literal_credential?(entry, expanded)
          [entry.to_s, expanded]
        end.freeze
      end

      # The runner's expansion; an unset name is this row's fault, the
      # sentence naming the key and the variable, never a value.
      def expand(key, value, name, entry, env, secrets)
        expanded, found = Rho::Runner::Secrets.expand(value, env)
        secrets.concat(found)
        expanded
      rescue Rho::Runner::Secrets::Unset => unset
        fault!(key, "#{name}.#{entry} names ${#{unset.variable}}, which is not set in the daemon's environment")
      end

      def fault!(key, sentence)
        raise RowFault, "mcp server \"#{key}\": #{sentence}"
      end
    end
  end
end
