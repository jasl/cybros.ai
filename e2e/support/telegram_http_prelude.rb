# The child keeps the real Telegram client and worker. Its existing URL injection
# points only this E2E process at the local synthetic Bot API endpoint.
begin
  require "rho/ingress-telegram"
rescue LoadError
  # Bundler's launcher runs before the child's own load path is installed.
else
  Rho::IngressTelegram::Client.prepend(Module.new do
    def initialize(token:, **options)
      super(token: token, **options, url: ENV.fetch("E2E_TELEGRAM_URL"), poll_timeout: 2)
    end
  end)
end
