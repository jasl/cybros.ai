require "json"
require "uri"
require "forwardable"

module Rho
  # Core deployment settings and the prepared plugin view share one saved file.
  # Environment values seed deployment; saved choices and explicit flags win.
  class Config < Data.define(:values, :plugins, :catalog, :resolved, :plugin_errors, :workspace_override, :home)
    SETTINGS_VERSION = 1
    KEYS = %w[bind api_only tools_root webui_root webui_access kernel_tools default_model conversation_title_model adaptations adaptations_dir executor_socket mode runner workspace fallback_models subagent_default nexus_public_url public_url].freeze
    # Who may open the WebUI once rho is paired: `open` lets any browser that
    # reaches the page in, `password` asks for rho's unlock password, `nexus`
    # asks for a Nexus sign-in; nil chooses by bind (open on loopback, nexus
    # elsewhere). Nexus sign-in stays available in every mode.
    WEBUI_ACCESS = %w[open nexus password].freeze
    MODES = %w[full agent runner].freeze
    ENV_KEYS = { "bind" => "RHO_BIND", "api_only" => "RHO_API_ONLY", "tools_root" => "RHO_TOOLS_ROOT", "webui_root" => "RHO_WEBUI_ROOT", "webui_access" => "RHO_WEBUI_ACCESS", "default_model" => "RHO_DEFAULT_MODEL", "adaptations" => "RHO_ADAPTATIONS", "executor_socket" => "RHO_EXECUTOR_SOCKET", "mode" => "RHO_MODE", "workspace" => "RHO_WORKSPACE", "nexus_public_url" => "RHO_NEXUS_PUBLIC_URL", "public_url" => "RHO_PUBLIC_URL" }.freeze
    SWITCHES = %w[api_only executor_socket subagent_default].freeze
    DEFAULTS = {
      "bind" => nil, "api_only" => false, "tools_root" => nil, "webui_root" => nil, "webui_access" => nil,
      "kernel_tools" => %w[
        nexus.graph.delegate_task nexus.human.ask
        nexus.memory.read nexus.memory.write nexus.memory.edit
        nexus.memory.ls nexus.memory.grep nexus.memory.delete
        nexus.conversation.spawn nexus.conversation.send
        nexus.conversation.status nexus.conversation.cancel
        nexus.conversation.search nexus.conversation.read
        nexus.skill.load nexus.tools.search nexus.tools.call
        nexus.runners.list nexus.models.list
      ],
      "default_model" => nil, "conversation_title_model" => "follow_current", "fallback_models" => [], "subagent_default" => true, "adaptations" => "auto",
      "adaptations_dir" => nil, "executor_socket" => true, "mode" => "full",
      "runner" => nil, "workspace" => nil, "nexus_public_url" => nil, "public_url" => nil,
    }.freeze

    class << self
      def load(path, env: ENV, flags: {}, home: nil)
        environment = ENV_KEYS.each_with_object({}) do |(key, name), values|
          value = env[name]
          next if value.nil? || value.empty?

          values[key] = SWITCHES.include?(key) ? %w[1 true yes on].include?(value.downcase) : value
        end
        explicit = flags.transform_keys(&:to_s).compact
        build(environment.merge(read(path)).merge(explicit), home: home,
          workspace_override: explicit.key?("workspace"))
      end

      def from_hash(hash, home: nil) = build(hash, home: home, workspace_override: true)

      def read(path)
        return {} unless path && File.file?(path)

        raw = JSON.parse(File.read(path, encoding: Encoding::UTF_8))
        unless JSONSchemer.schema({ "type" => "object" }).valid?(raw)
          raise ConfigurationError, "#{path} must contain a JSON object"
        end
        # The current document can contain write-only plugin credentials. Keep
        # their existing StateFile ownership and permission checks on reads too.
        raw["settings_version"] == SETTINGS_VERSION ? StateFile.new(path).read : raw
      rescue JSON::ParserError
        raise ConfigurationError, "#{path} is not valid JSON", cause: nil
      end

      private

        def build(hash, home:, workspace_override:)
          document = hash.to_h.transform_keys(&:to_s)
          version = document.fetch("settings_version", SETTINGS_VERSION)
          unless version == SETTINGS_VERSION
            raise ConfigurationError, "settings format requires migration before loading"
          end
          envelope = { "type" => "object", "properties" => {
            "subagent_default" => { "type" => "boolean" },
            "conversation_title_model" => { "type" => ["string", "null"], "pattern" => "\\S" },
            "fallback_models" => { "type" => "array", "items" => { "type" => "string", "minLength" => 1 } },
            "plugins" => { "type" => "object", "additionalProperties" => {
              "type" => "object", "properties" => {
                "enabled" => { "type" => "boolean" },
                "source" => { "type" => "object" },
                "configuration_version" => { "type" => "integer", "minimum" => 1 },
              },
            } },
          } }
          unless JSONSchemer.schema(envelope).valid?(document)
            raise ConfigurationError, "invalid settings file envelope"
          end
          plugins = document.fetch("plugins", {}).to_h
          catalog = Extensions::Catalog.new(home: home, entries: plugins)
          new(values: DEFAULTS.merge(document.slice(*KEYS)), plugins: plugins,
            catalog: catalog, workspace_override: workspace_override, home: home)
        end
    end

    KEYS.each { |key| define_method(key) { @values.fetch(key) } }

    def initialize(values:, plugins:, catalog:, workspace_override:, home: nil)
      @home, @catalog = home, catalog
      @plugins = immutable(plugins)
      @values = values.merge(
        "mode" => one_of(values.fetch("mode"), "mode", MODES),
        "runner" => presence(values["runner"]),
        "workspace" => room(values["workspace"], values["mode"]),
        "fallback_models" => fallback_list(values.fetch("fallback_models"), values.fetch("mode")),
        "bind" => presence(values["bind"]), "default_model" => presence(values["default_model"]),
        "conversation_title_model" => values["conversation_title_model"]&.strip,
        "tools_root" => expanded(values["tools_root"]), "webui_root" => expanded(values["webui_root"]),
        "webui_access" => (presence(values["webui_access"]) && one_of(values["webui_access"], "webui_access", WEBUI_ACCESS)),
        "kernel_tools" => string_list(values["kernel_tools"], "kernel_tools"),
        "adaptations" => Adaptations.knob(values["adaptations"]),
        "adaptations_dir" => expanded(values["adaptations_dir"]),
        "nexus_public_url" => validated_public_url(values["nexus_public_url"], "nexus_public_url"),
        "public_url" => validated_public_url(values["public_url"], "public_url")
      )
      SWITCHES.each { |key| @values[key] = values[key] == true || truthy?(values[key]) }
      @workspace_override = workspace_override && !workspace.nil?
      @resolved, @plugin_errors = {}, catalog.failures.dup
      catalog.descriptors.each do |id, descriptor|
        entry = plugins.fetch(id, {})
        begin
          version = entry.fetch("configuration_version", descriptor.version)
          unless version == descriptor.version
            raise ConfigurationError, "configuration version #{version} requires migration to #{descriptor.version}"
          end
          @resolved[id] = descriptor.schema.normalize(entry.fetch("configuration", {}))
        rescue ConfigurationError => error
          @plugin_errors[id] = error.message
        end
      end
      # Missing dependencies withdraw only their dependents. Iterate because a
      # dependency can itself become unavailable through another dependency.
      loop do
        unavailable = catalog.descriptors.values.select do |descriptor|
          plugin_requested?(descriptor.id) && !@plugin_errors.key?(descriptor.id) &&
            descriptor.requires.any? { |id| !plugin_enabled?(id) }
        end
        break if unavailable.empty?

        unavailable.each do |descriptor|
          missing = descriptor.requires.reject { |id| plugin_enabled?(id) }
          @plugin_errors[descriptor.id] = "Requires available plugins: #{missing.join(", ")}"
        end
      end
      @values = immutable(@values)
      @resolved.transform_values! do |resolved|
        resolved.with(overrides: immutable(resolved.overrides), value: immutable(resolved.value))
      end
      super(values: @values, plugins: @plugins, catalog: catalog,
        resolved: @resolved.freeze, plugin_errors: @plugin_errors.freeze,
        workspace_override: @workspace_override, home: home)
    end

    def workspace_selection(home) = workspace_override ? workspace : home.settings_workspace || workspace
    def to_h = @values.merge("settings_version" => SETTINGS_VERSION, "plugins" => plugins)
    def with(changes, home: @home)
      self.class.send(:build, to_h.merge(changes), home: home, workspace_override: workspace_override)
    end

    def plugin_enabled?(id)
      !@plugin_errors.key?(id) && plugin_requested?(id)
    end

    def plugin_requested?(id)
      descriptor = @catalog.descriptors[id]
      !!(descriptor && descriptor.modes.include?(mode) &&
        (descriptor.source["kind"] != "package" || @plugins.dig(id, "source") == descriptor.source) &&
        @plugins.fetch(id, {}).fetch("enabled", descriptor.default_enabled) == true)
    end

    def plugin_configuration(id) = @resolved.fetch(id) { catalog.fetch(id).schema.normalize({}) }.value
    def plugin_resolution(id) = @resolved.fetch(id) { catalog.fetch(id).schema.normalize({}) }

    class Current
      extend Forwardable
      def_delegators :@current, *Config::KEYS.map(&:to_sym), :plugins, :catalog, :plugin_errors,
        :workspace_override, :workspace_selection, :plugin_enabled?, :plugin_requested?, :plugin_configuration,
        :plugin_resolution, :to_h, :with

      def initialize(config) = @current = config
      def apply(config)
        @current = config
        self
      end
    end

    private

      def immutable(value) = JSON.parse(JSON.generate(value), freeze: true)

      def validated_public_url(value, name)
        text = presence(value)
        return nil if text.nil?

        uri = URI.parse(text)
        unless %w[http https].include?(uri.scheme) && uri.host && !uri.userinfo && !uri.query && !uri.fragment
          raise ConfigurationError, "#{name} must be an http(s) URL without credentials, query or fragment"
        end
        text.delete_suffix("/")
      rescue URI::InvalidURIError
        raise ConfigurationError, "#{name} must be an http(s) URL"
      end

      def presence(value)
        text = value.to_s
        text.empty? ? nil : text
      end

      # A runner constructs no member plane and adopts nothing: a room
      # named there would be a promise the boot cannot keep.
      def room(value, rho_mode)
        address = presence(value)
        raise ConfigurationError, "workspace needs mode full or agent" if address && rho_mode == "runner"

        address
      end

      def fallback_list(value, rho_mode)
        models = value.map(&:strip).reject(&:empty?).uniq
        if !models.empty? && rho_mode == "runner"
          raise ConfigurationError, "fallback_models needs mode full or agent"
        end
        models
      end

      def truthy?(value) = %w[1 true yes on].include?(value.to_s.downcase)

      # `~` is what an operator writes in a settings file, and a tool
      # resolving paths against a literal "~/src" would create a
      # directory called "~".
      def expanded(value)
        path = presence(value)
        path && File.expand_path(path)
      end

      def string_list(value, name)
        list = Array.try_convert(value)
        raise ConfigurationError, "#{name} must be an array of strings" if list.nil?

        list.map { |entry| entry.to_s }.reject(&:empty?).freeze
      end

      def one_of(value, name, words)
        word = value.to_s.strip.downcase
        unless words.include?(word)
          raise ConfigurationError, "#{name} must be one of #{words.join(", ")}, got #{value.inspect}"
        end

        word
      end
  end
end
