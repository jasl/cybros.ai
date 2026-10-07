class Admin::ModelProviders::ModelTestsController < Admin::ModelProviders::BaseController
  before_action :load_models
  before_action :load_model
  rate_limit to: 10, within: 3.minutes, by: -> { Current.user.id }, only: :create,
    with: -> { @rate_limited = true; render :show, status: :too_many_requests }

  def show
  end

  def create
    fields = params.expect(model_test: [:model, :expected_lock_version])
    @test_result = ModelProviders::TestModel.call(
      account: account, provider_id: provider_id, model_ref: @model.fetch(:ref),
      expected_lock_version: expected_lock_version(fields)
    )
    load_provider
    load_models
    render :show
  end

  private

    def load_model
      model = (action_name == "create" ? params.expect(model_test: [:model])[:model] : params[:model]).to_s
      @model = @models.find { |row| row.fetch(:ref) == model }
      raise ActiveRecord::RecordNotFound if @model.nil?
    end
end
