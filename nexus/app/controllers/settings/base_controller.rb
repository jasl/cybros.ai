# Personal settings commands operate on the authenticated member's own records.
class Settings::BaseController < ApplicationController
  private

    def consume_sso_proof(action)
      Sso::Proof.consume(session: Current.session, action: action, target: Current.user.public_id)
    end
end
