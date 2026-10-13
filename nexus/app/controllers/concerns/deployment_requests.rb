module DeploymentRequests
  extend ActiveSupport::Concern

  included do
    before_action :no_store
  end

  private

    def deployment_client
      @deployment_client ||= Nexus::Deployment::Client.new
    end

    def deployment_candidate
      fields = params.expect(candidate: [:release, images: [[:name, :reference]]])
      Nexus::Deployment::Release.new(
        release: fields[:release].to_s,
        images: fields.fetch(:images, []).map do |image|
          Nexus::Deployment::Image.new(name: image[:name].to_s, reference: image[:reference].to_s)
        end
      )
    end

    def deployment_check_options
      fields = params.permit(release_check: [:tag, :backup]).fetch(:release_check, {})
      { tag: fields.fetch(:tag, "latest").to_s, backup: ActiveModel::Type::Boolean.new.cast(fields.fetch(:backup, true)) }
    end

    def deployment_backup
      ActiveModel::Type::Boolean.new.cast(params.permit(:backup).fetch(:backup, true))
    end

    def deployment_cursor
      params.permit(:cursor)[:cursor]&.to_s
    end

    def deployment_json(result, resource:)
      if result.success?
        value = case resource
        when :deployment then API::DeploymentPresenter.state(result.data)
        when :upgrade then API::DeploymentPresenter.receipt(result.data)
        when :log then API::DeploymentPresenter.log(result.data)
        else raise ArgumentError, "Unknown deployment resource"
        end
        render json: { resource => value }, status: result.status
      else
        render json: { error: API::DeploymentPresenter.error(result.error) }, status: result.status
      end
    end
end
