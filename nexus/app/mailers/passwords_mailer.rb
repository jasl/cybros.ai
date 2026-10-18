class PasswordsMailer < ApplicationMailer
  def reset(identity)
    @identity = identity
    mail to: identity.email
  end
end
