require "async/semaphore"

module Rho
  # The running daemon owns settings writes. CLI and browser changes share the
  # same validation, private file and runtime application edge.
  class Settings
    class ApplyError < Error; end

    DEPLOYMENT_KEYS = %w[mode bind api_only webui_root executor_socket installation_file].freeze
    EDITABLE_KEYS = (Config::KEYS - DEPLOYMENT_KEYS).freeze
    PUBLIC_KEYS = %w[
      bash_timeout_seconds tools_root extensions extension_paths kernel_tools
      default_model fallback_model image_model compose adaptations adaptations_dir
      compaction lifecycle_hooks runner workspace checkpoints web nexus_public_url
    ].freeze

    def initialize(home:, config:, apply:, validate: ->(_config, _changes) { })
      @home, @config, @apply, @validate = home, config, apply, validate
      @writing = Async::Semaphore.new(1)
    end

    def update(patch, before_save: nil)
      changes = patch.to_h.transform_keys(&:to_s)
      unknown = changes.keys - EDITABLE_KEYS
      unless unknown.empty?
        raise ConfigurationError, "#{unknown.first} is not an editable agent setting"
      end

      @writing.acquire do
        previous = Config.from_hash(@config.to_h)
        candidate = @config.with(changes)
        if changes.key?("workspace") && @config.workspace_override
          raise ConfigurationError, "workspace is fixed by --workspace; remove that launch flag before choosing a default"
        end
        @validate.call(candidate, changes.keys)
        before_save&.call
        @home.write_settings(Config.read(@home.settings_path).merge(candidate.to_h.slice(*changes.keys)))
        @config.apply(candidate)
        begin
          @apply.call(previous, changes.keys)
        rescue StandardError => error
          raise ApplyError, "Settings were saved, but applying them failed (#{error.class.name}). Check the connection and try saving again.", cause: nil
        end
        @config
      end
    end
  end
end
