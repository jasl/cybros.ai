# Readiness: a process is ready once its catalog compiled and booted. A boot
# failure keeps both readiness and new model work closed.
class HealthController < ActionController::Base
  def show
    if ModelCatalog.ready?
      render plain: "OK"
    else
      render plain: "model catalog unavailable", status: :service_unavailable
    end
  end
end
