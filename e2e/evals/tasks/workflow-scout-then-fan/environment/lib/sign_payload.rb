require "openssl"

# Signs a payload with a shared secret and checks a signature against it.
class SignPayload
  def initialize(secret)
    @secret = secret
  end

  def sign(payload)
    OpenSSL::HMAC.hexdigest("SHA256", @secret, payload)
  end

  def valid?(payload, signature)
    sign(payload) == signature
  end
end
