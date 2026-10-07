class Admin::ModelProviders::ModelDiscoveriesController < Admin::ModelProviders::BaseController
  def show
  end

  def create
    fields = params.expect(model_discovery: [:expected_lock_version])
    @discovery = ModelProviders::DiscoverModels.call(
      account: account, provider_id: provider_id, expected_lock_version: expected_lock_version(fields)
    )
    load_provider
    if @discovery.success?
      models = configuration.fetch(:models)
      @models_by_id = models.group_by do |row|
        row.fetch(:definition)&.fetch("model_id", nil) || Nexus::ModelRef.parse(row.fetch(:model)).model_ref
      end
      @models_by_ref = models.index_by { |row| row.fetch(:model) }
    end
    status = @discovery.success? ? :ok : (@discovery.outcome == :stale ? :conflict : :unprocessable_entity)
    render :show, status: status
  end
end
