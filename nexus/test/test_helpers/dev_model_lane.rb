# The dev/mock lane's test-side driver: every selection here is a REAL ModelSelection::Resolver
# resolution over the mounted dev catalog — the same compile path, policy gate, credentialless
# credential resolution, and selection construction run. The M2 fake port is gone; nothing
# constructs a ResolvedModelSelection by hand.
module DevModelLane
  MODELS = {
    "text_generation" => "dev/mock-text",
    "image_generation" => "dev/mock-image",
    "speech_generation" => "dev/mock-speech",
    "transcription" => "dev/mock-transcription",
    "embedding" => "dev/mock-embedding",
  }.freeze

  # Priced fixture model for admission and settlement cost-path tests.
  PRICED_TEXT_MODEL = "dev/mock-priced".freeze
  # `pricing:` declared with nothing under it: the platform does not compute
  # this lane's cost, which is not the same claim as the lane being free.
  UNMETERED_TEXT_MODEL = "dev/mock-unmetered".freeze
  # The lane every pre-send protection is blind to: no declared window,
  # so nothing self-fits, nothing budgets, and the sealed request's byte
  # bound is the only wall left.
  WINDOWLESS_TEXT_MODEL = "dev/mock-windowless".freeze
  # mock-text's row on a window a case sizes: the lane a replay walk fills
  # to its edge. Built per test (`windowed_catalog`), never a mounted row.
  WINDOWED_TEXT_MODEL = "dev/mock-windowed".freeze
  # A second windowed model on the same provider: the target a model
  # switch lands on, whose origin rule refuses the first one's blobs.
  WINDOWED_OTHER_MODEL = "dev/mock-windowed-other".freeze

  module_function

  # mock-text's row on a window of `input_tokens`, under both windowed
  # names (the second on `other_input_tokens` when a case switches to a
  # smaller window), merged into the mounted catalog and validated as any
  # row is — the value a case stubs `ModelCatalog.current` with.
  def windowed_catalog(input_tokens:, other_input_tokens: input_tokens)
    current = ModelCatalog.current
    row = current.models.fetch(MODELS.fetch("text_generation"))
    windowed = lambda do |tokens|
      row.merge("capabilities" => row.fetch("capabilities").merge(
        "limits" => row.dig("capabilities", "limits").merge("input_tokens" => tokens)
      ))
    end
    names = [WINDOWED_TEXT_MODEL, WINDOWED_OTHER_MODEL]
    catalog = current.with(models: current.models.merge(
      WINDOWED_TEXT_MODEL => windowed.(input_tokens), WINDOWED_OTHER_MODEL => windowed.(other_input_tokens)
    ))
    names.each do |name|
      ModelCatalog::CatalogValidation.validate_change(catalog.models, catalog.selectors, name, catalog.providers)
    end
    catalog
  end

  # THE PROFILE, COMPOSED THE WAY PRODUCTION COMPOSES IT: from the mounted
  # catalog through the same builder the resolver uses. It replaced
  # `ProfileRegistry.fetch(id)` — there is no table of profiles to fetch from
  # any more, and building one here is what a consumer does.
  def profile_for(model_ref)
    snapshot = ModelCatalog.current
    ModelCatalog::ProfileBuilder.call(
      model_ref: model_ref,
      provider: snapshot.providers.fetch(model_ref.split("/", 2).first),
      model: snapshot.models.fetch(model_ref)
    )
  end

  # Every model the mounted catalog knows, composed. The replacement for
  # `ProfileRegistry.each_profile`, and a truer one: it walks what this
  # deployment actually serves rather than what a library shipped.
  def each_catalog_profile
    snapshot = ModelCatalog.current
    return to_enum(:each_catalog_profile) unless block_given?

    snapshot.models.each_key { |model_ref| yield profile_for(model_ref) }
  end

  # Idempotent lane enablement: the resolver refuses a disabled lane, and
  # transactional tests roll the policy row back after each test.
  def ensure_enabled!(account = Account.sole)
    policy = ModelProviderPolicy.find_by(account: account, provider_id: "dev")
    return if policy&.enabled?

    ModelProviders::EnableLane.call(
      account: account, provider_id: "dev",
      expected_lock_version: policy&.lock_version
    )
  end

  def submission_for(workload, model: nil, reasoning_effort: nil)
    Nexus::SubmittedModelSelection.new(
      model: model || MODELS.fetch(workload), reasoning_effort: reasoning_effort
    )
  end

  def resolve(workload:, account: Account.sole, model: nil, reasoning_effort: nil,
              configuration: {}, submitted: nil)
    ensure_enabled!(account)
    ModelSelection::Resolver.new.resolve(
      account: account, workload: workload,
      submitted: submitted || submission_for(workload, model: model, reasoning_effort: reasoning_effort),
      configuration: configuration
    )
  end

  # The fake's `.selection` shape, now backed by the real resolver: returns
  # the resolved selection or raises loudly with the typed refusal.
  def selection(workload:, account: Account.sole, model: nil, reasoning_effort: nil,
                configuration: {})
    result = resolve(
      workload: workload, account: account, model: model,
      reasoning_effort: reasoning_effort, configuration: configuration
    )
    unless result.resolved?
      raise "dev lane refused #{workload}: #{result.refusal.inspect}"
    end

    result.selection
  end

  # Test construction mirrors the production aggregate without reintroducing
  # the removed selection snapshot. The selection is only an in-memory setup
  # value; the Invocation keeps its narrow semantic request facts.
  def invocation_attributes(selection)
    {
      provider_id: selection.provider_id,
      model_ref: selection.model_ref,
      reasoning_effort: selection.reasoning.effort,
      request_options: selection.generation_config.to_h,
      admission_deadline_seconds:
        selection.execution_profile.total_execution_deadline_seconds,
    }
  end

  def create_invocation!(one_shot:, selection: nil, **attributes)
    resolved = selection || self.selection(
      workload: one_shot.workload, account: one_shot.account
    )
    ModelInvocation.create!(
      one_shot: one_shot,
      **invocation_attributes(resolved),
      **attributes
    )
  end

  def profile_for_invocation(invocation)
    profile_for("#{invocation.provider_id}/#{invocation.model_ref}")
  end

  def profile_with(profile, **overrides) = profile.with(**overrides)

  # The port for command injection (OneShots::Create and friends): the real
  # resolver IS the port duck; callers must have enabled the lane first
  # (setup), because injection sites resolve inside guarded transactions.
  def port = ModelSelection::Resolver.new
end
