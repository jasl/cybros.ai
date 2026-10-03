require "test_helper"

class ApplicationMailerTest < ActionMailer::TestCase
  test "SMTP readiness requires both a transport and canonical domain origin" do
    previous_origin = Rails.application.routes.default_url_options.dup
    previous_smtp_address = ENV["SMTP_ADDRESS"]

    ActionMailer::Base.stub(:delivery_method, :smtp) do
      Rails.application.routes.default_url_options = {}
      ENV["SMTP_ADDRESS"] = "smtp.example"
      refute ApplicationMailer.delivery_configured?

      Rails.application.routes.default_url_options =
        { host: "nexus.example", protocol: "https", port: 443 }
      ENV["SMTP_ADDRESS"] = nil
      refute ApplicationMailer.delivery_configured?

      ENV["SMTP_ADDRESS"] = "smtp.example"
      assert ApplicationMailer.delivery_configured?
    end
  ensure
    Rails.application.routes.default_url_options = previous_origin
    ENV["SMTP_ADDRESS"] = previous_smtp_address
  end
end
