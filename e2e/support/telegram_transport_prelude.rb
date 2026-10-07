# Register the real plugin and its named group profile in the product daemon,
# while the journey drives its Runtime with a recording Telegram client. No Bot
# request may escape from this child, even if background registration changes.
begin
  require "rho/ingress-telegram"
rescue LoadError
  # The bundle launcher runs before the product's load path is installed.
else
  Rho::IngressTelegram::Runtime.prepend(Module.new do
    def start; end
  end)
  Rho::IngressTelegram::Client.prepend(Module.new do
    def call(*)
      raise "Telegram network IO is forbidden in the E2E daemon"
    end
  end)
end
