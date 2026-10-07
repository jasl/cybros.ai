require "yaml"

module E2E
  # WHICH LANE A MODEL REF NAMES. A ref is the catalog's `provider/model`, and its first segment is
  # the provider that serves it: `openrouter/z-ai/glm-5.3` through the broker,
  # `deepseek/deepseek-flash` direct on the official API. Every paid path reads the provider here —
  # a live journey enabling the providers its models need, a manual client building the lane it
  # calls — so a direct first-party lane runs without editing callers, and the floor a bench names
  # is the one it measures.
  #
  # The wire and the endpoint are the CATALOG's (`nexus/config/model_catalog/*.yml`): a manual
  # client speaks what the kernel would speak to that provider, never a harness restatement of it.
  # The key's NAME is the one thing the catalog cannot say — the value is the operator's and is
  # never printed, logged or put on a command line.
  module ProviderLanes
    # Where each provider's key is read from, under the catalog's provider ids. A provider absent
    # here has no e2e lane: a live journey SKIPS rather than failing (an unconfigured provider is a
    # fact about this machine, not a defect in the code under test), and a manual client refuses
    # before a request is built. `deepseek` is the direct lane — the official API
    # (`60_deepseek.yml`, `deepseek_responses`) — installed the same way as a broker: the key under
    # the provider id; nothing on the install path knows a broker from a first party. `xai` is the
    # direct xAI API (`70_xai.yml`, `xai_responses`) under the same rule.
    KEY_NAMES = {
      "openrouter" => "OPENROUTER_API_KEY",
      "deepseek" => "DEEPSEEK_API_KEY",
      "anthropic" => "ANTHROPIC_API_KEY",
      "openai_api" => "OPENAI_API_KEY",
      "gemini" => "GEMINI_API_KEY",
      "xai" => "XAI_API_KEY",
    }.freeze

    CATALOG_FILES = File.expand_path("../../nexus/config/model_catalog/*.yml", __dir__)

    # A provider's lane: the catalog's wire and endpoint, the key's name.
    Lane = Data.define(:provider_id, :format, :base_url, :key_name)
    # A ref resolved: its lane, and the id the wire carries for it (the ref minus its provider
    # segment, unless the catalog row names another).
    Route = Data.define(:ref, :lane, :model)

    module_function

    def provider_of(model_ref) = model_ref.to_s.split("/", 2).first

    # The key NAME, never the value; nil for a provider with no e2e lane.
    def key_name_for(model_ref) = KEY_NAMES[provider_of(model_ref)]

    # EVERY PROVIDER A SET OF MODELS NEEDS, by the key each is read from: one world may serve
    # several models (the evals lane runs a whole tier under one daemon configuration), and the
    # direct DeepSeek floor sits beside the broker's models, so enabling only the first model's
    # provider leaves the others' lanes refused. A provider with no e2e lane maps to nil.
    def provider_keys_for(model_refs)
      model_refs.map { |ref| provider_of(ref) }.uniq.to_h { |provider| [provider, KEY_NAMES[provider]] }
    end

    # A ref the catalog does not name is refused by name: a bare broker id such as
    # `deepseek/deepseek-v4.1-flash` would otherwise read as the direct provider's model and be
    # sent to the wrong endpoint under a name that provider does not list.
    def route(model_ref)
      ref = model_ref.to_s
      row = catalog.fetch("models").fetch(ref) do
        raise ArgumentError, "#{ref.inspect} is not a catalog model ref; name one as the catalog does " \
                             "(<provider>/<model>, e.g. deepseek/deepseek-flash or openrouter/z-ai/glm-5.3)"
      end
      provider_id, tail = ref.split("/", 2)
      Route.new(ref: ref, lane: lane(provider_id), model: Hash(row).fetch("model_id", tail))
    end

    def lane(provider_id)
      row = catalog.fetch("providers").fetch(provider_id) do
        raise ArgumentError, "no catalog provider #{provider_id.inspect}; the catalog names #{catalog.fetch("providers").keys.join(", ")}"
      end
      key_name = KEY_NAMES.fetch(provider_id) do
        raise ArgumentError, "provider #{provider_id.inspect} has no e2e key; the lanes are #{KEY_NAMES.keys.join(", ")}"
      end
      Lane.new(provider_id: provider_id, format: row.fetch("api_format"), base_url: row.fetch("base_url"), key_name: key_name)
    end

    # The shipped fragments' providers and models, each by id.
    def catalog
      @catalog ||= begin
        fragments = Dir[CATALOG_FILES].sort.map { |path| YAML.safe_load_file(path) }
        %w[providers models].to_h { |key| [key, fragments.map { |fragment| Hash(fragment[key]) }.reduce({}, :merge)] }.freeze
      end
    end
  end
end
