# Every Runner has one human manager, independent of its assignment ACL.
# Manager commands resolve through that relationship, so another human's
# Runner is not found rather than forbidden.
class Runners::BaseController < ApplicationController
  private

    def runner
      @runner ||= Current.user.managed_executors.find_by!(
        public_id: params[:runner_public_id] || params[:public_id]
      )
    end
end
