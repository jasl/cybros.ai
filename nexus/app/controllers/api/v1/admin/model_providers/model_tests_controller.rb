class API::V1::Admin::ModelProviders::ModelTestsController < API::V1::Admin::ModelProviders::BaseController
  rate_limit to: 10, within: 3.minutes, by: -> { Current.user.id }, only: :create

  def create
    fields = params.expect(command: [:model, :expected_lock_version])
    model = fields[:model].to_s
    catalog = ModelSelection::Resolver.effective_provider_catalog(account, snapshot, provider_id)
    return render_not_found unless ModelProviderConfig.provider_lane_ref?(provider_id, model) && catalog.models.key?(model)

    result = ModelProviders::TestModel.call(
      account: account, provider_id: provider_id, model_ref: model,
      expected_lock_version: expected_version(fields)
    )
    render json: { model_test: result.to_h, model_provider: lane(provider_id) }
  end
end
