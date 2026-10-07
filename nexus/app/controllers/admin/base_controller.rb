class Admin::BaseController < ApplicationController
  before_action :require_admin

  private

    # Role failures are honest 403s: there is no concealment tier between
    # members of the single trust domain.
    def require_admin
      head :forbidden unless Current.user.admin?
    end

    def sidebar_nav_partial
      "layouts/shared/admin_nav"
    end
end
