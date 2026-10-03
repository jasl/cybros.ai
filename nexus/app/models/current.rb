class Current < ActiveSupport::CurrentAttributes
  # Exactly one principal per request: a Session (browser cookie or api
  # bearer) or an AccessToken resolved on its own plane.
  attribute :session, :access_token

  def account
    session&.account || access_token&.account
  end

  def identity
    session&.identity
  end

  def user
    session&.user || access_token&.user
  end
end
