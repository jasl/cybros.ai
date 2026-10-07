require "fileutils"
require "json"
require "yaml"

module E2E
  # THE DEV LANE, POINTED AT THIS RUN'S FAKE PROVIDER.
  #
  # Nexus ships no `dev` provider — the lane's catalog data is test-owned
  # (`nexus/test/support/model_catalog/90_dev.yml`) and mounted only by the
  # RAILS_ENV=test helper. The e2e server boots development, so without this
  # there is no dev provider for it at all, and the fake provider it could
  # have talked to has no address anywhere in its configuration.
  #
  # So the harness writes the lane, and writes it through THE OPERATOR'S OWN
  # SEAM — the catalog override directory — rather than through a test hook.
  # That seam is the one an operator uses to add a provider, and until now
  # nothing had ever exercised it end to end.
  #
  # THE FRAGMENT IS COPIED, NOT AUTHORED. Its body comes from the test-owned
  # dev fragment with one value replaced: the provider's `base_url`, which
  # only this run knows because the mock chose its own port. Copying is what
  # keeps the two mounts from drifting into two different dev lanes. A copy
  # also supplies the isolated API-key lane used by model management.
  # Private web-fetch and attachment rows fit their larger payloads without
  # changing the small windows other journeys exercise. A named real-model diagnostic
  # may also add whole model overrides to this temporary fragment.
  class CatalogOverlay
    SOURCE = "test/support/model_catalog/90_dev.yml".freeze
    # `.development.yml` and not a bare name: the environment tier keeps this
    # harness-owned lane out of every other environment.
    FILENAME = "90_e2e_dev.development.yml".freeze
    WEB_FETCH_MODEL = "dev/mock-web-fetch".freeze
    ATTACHMENTS_MODEL = "dev/mock-rho-attachments".freeze
    DOCUMENT_MODEL = "dev/mock-document".freeze
    PROMPT_FORMAT_MODEL = "dev/mock-prompt-format".freeze
    REASONING_SWITCH_MODEL = "dev/mock-reasoning-switch".freeze
    attr_reader :dir, :path

    def initialize(nexus_root:, provider_base_url:, model_overrides: {})
      @nexus_root = nexus_root
      @provider_base_url = provider_base_url
      @model_overrides = model_overrides
      @dir = Dir.mktmpdir("cybros-e2e-catalog-")
      @path = File.join(@dir, FILENAME)
    end

    def install
      fragment = YAML.safe_load_file(File.join(@nexus_root, SOURCE))
      fragment.fetch("providers").fetch("dev")["base_url"] = @provider_base_url
      # A separate lane keeps the management journey's enable/disable and key
      # changes from changing the credentialless lane other journeys share.
      # Copy the nested data too: shared objects emit YAML aliases, which the
      # catalog's safe loader deliberately does not accept.
      keyed = JSON.parse(JSON.generate(fragment))
      fragment.fetch("providers")["e2e-key"] = keyed.fetch("providers").fetch("dev").merge("credentials" => "api_key")
      fragment.fetch("models")["e2e-key/mock-keyed-text"] = keyed.fetch("models").fetch("dev/mock-text")
      # The rendered head alone is 12,240 o200k tokens; with rho's prefix,
      # the call and the result envelope its first read is about 14,000.
      # The mock's reported usage puts that continuation near 16,200, so
      # a finite 32K row leaves room for the unchanged spill/paging contract.
      web_fetch = JSON.parse(JSON.generate(fragment.fetch("models").fetch("dev/mock-text")))
      web_fetch["model_id"] = "mock-text"
      web_fetch.fetch("capabilities").fetch("limits")["input_tokens"] = 32_768
      fragment.fetch("models")[WEB_FETCH_MODEL] = web_fetch
      # Two images cost 5,000 tokens before text and history; the queued
      # third turn needs about 7,200 in assembly. A finite 12K row fits
      # that attachment journey without widening the shared 8K model.
      attachments = JSON.parse(JSON.generate(fragment.fetch("models").fetch("dev/mock-text")))
      attachments["model_id"] = "mock-text"
      attachments.fetch("capabilities").fetch("limits")["input_tokens"] = 12_288
      fragment.fetch("models")[ATTACHMENTS_MODEL] = attachments
      # Native PDF tests need an explicit document-capable row; the shared
      # image model still exercises PDF fallback through ordinary file tools.
      document = JSON.parse(JSON.generate(attachments))
      document.fetch("capabilities")["input_modalities"] = %w[image file]
      fragment.fetch("models")[DOCUMENT_MODEL] = document
      # A model-specific sending format must not rewrite the shared model's
      # stored conversation input or follow it into another model's request.
      prompt_format = JSON.parse(JSON.generate(fragment.fetch("models").fetch("dev/mock-text")))
      prompt_format["model_id"] = "mock-text"
      prompt_format["wire_options"] = { "prompt_format" => "qwen3_5" }
      fragment.fetch("models")[PROMPT_FORMAT_MODEL] = prompt_format
      # The shared model always reasons. Its switchable twin exercises an
      # explicit off request through the same Responses provider echo.
      reasoning_switch = JSON.parse(JSON.generate(fragment.fetch("models").fetch("dev/mock-text")))
      reasoning_switch["model_id"] = "mock-text"
      reasoning_switch.fetch("capabilities").fetch("reasoning")["disable_supported"] = true
      fragment.fetch("models")[REASONING_SWITCH_MODEL] = reasoning_switch
      fragment.fetch("models").merge!(@model_overrides)
      File.write(@path, banner + fragment.to_yaml)
      self
    end

    # The value the Nexus child needs in order to read this instead of its own
    # `config.d`, which keeps a run from writing into the checkout it is
    # running from.
    def child_env = { "MODEL_CATALOG_OVERRIDE_DIR" => @dir }

    def release
      FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
      @dir = nil
    end

    private

      def banner
        <<~YAML
          # Written by the E2E harness for one run. The body is
          # nexus/#{SOURCE} with the dev provider's base_url replaced by the
          # address the fake provider bound this run, an isolated API-key lane,
          # and finite web-fetch/attachment windows, plus any explicitly
          # requested model overrides for this run alone.
        YAML
      end
  end
end
