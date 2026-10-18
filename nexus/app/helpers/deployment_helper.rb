module DeploymentHelper
  def deployment_phase_labels = t("deployment.phases").stringify_keys
  def deployment_status_labels = t("deployment.statuses").stringify_keys

  def deployment_source_url(candidate)
    if candidate&.source_url.present?
      uri = URI.parse(candidate.source_url)
      candidate.source_url if %w[http https].include?(uri.scheme) && uri.host.present? && uri.userinfo.nil?
    end
  rescue URI::InvalidURIError
    nil
  end

  def deployment_up_to_date?(deployment)
    deployment&.candidate && deployment.installed == deployment.candidate.target
  end
end
