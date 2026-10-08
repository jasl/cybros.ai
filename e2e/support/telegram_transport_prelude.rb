# Register the real plugin and its named group profile in the product daemon,
# while the journey drives its Runtime with a recording Telegram client. No Bot
# request may escape from this child, even if background registration changes.
begin
  require "rho/ingress-telegram"
rescue LoadError
  # The bundle launcher runs before the product's load path is installed.
else
  # Permission journeys need the real Browser tool declarations to be active.
  # Reuse its synthetic driver so startup is independent of host Playwright;
  # the journey still asserts forbidden calls are rejected before any claim.
  require "rho/browser"
  require_relative "../../agents/rho/rho-browser/test/support"
  Rho::Browser.driver_factory = -> { BrowserTest::FakeDriver.new }

  Rho::IngressTelegram::Runtime.prepend(Module.new do
    def start; end
  end)
  Rho::IngressTelegram::Client.prepend(Module.new do
    def call(*)
      raise "Telegram network IO is forbidden in the E2E daemon"
    end
  end)
end
