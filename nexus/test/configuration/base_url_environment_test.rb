require "test_helper"
require "json"
require "open3"
require "rbconfig"

class BaseUrlEnvironmentTest < ActiveSupport::TestCase
  OUTPUT_PREFIX = "BASE_URL_ENVIRONMENT_TEST=".freeze
  ERROR_MESSAGE =
    "BASE_URL must use http or https and include a host, for example https://nexus.example.com".freeze
  # dotenv loads from `before_configuration`, which fires while `config/application` is still being
  # required — and an EMPTY file list means ".env", not "nothing". So the redirect has to happen
  # before that require and has to name a real empty file, or a developer's local.env steers the
  # very variables this test deletes to exercise their defaults.
  BOOT_SCRIPT = <<~'RUBY'.freeze
    require "json"
    require_relative "config/boot"
    require "rails"
    require "dotenv"
    require "dotenv/rails"
    Dotenv::Rails.files = [File::NULL]

    require_relative "config/application"
    Rails.application.initialize!

    configuration = {
      routes: Rails.application.routes.default_url_options,
      mailer: Rails.application.config.action_mailer.default_url_options,
      assume_ssl: Rails.application.config.assume_ssl,
      force_ssl: Rails.application.config.force_ssl,
    }
    puts "BASE_URL_ENVIRONMENT_TEST=#{JSON.generate(configuration)}"
  RUBY

  test "development boots with a relaxed HTTP origin" do
    configuration = boot_configuration(
      environment: "development",
      base_url: "http://127.0.0.1:3300/a/path?query=yes#fragment"
    )
    expected_origin = { "host" => "127.0.0.1", "protocol" => "http", "port" => 3300 }

    assert_equal expected_origin, configuration.fetch("routes")
    assert_equal expected_origin, configuration.fetch("mailer")
  end

  test "production boots with a relaxed HTTPS origin and derives SSL defaults" do
    configuration = boot_configuration(
      environment: "production",
      base_url: "https://localhost:3443/a/path?query=yes#fragment"
    )
    expected_origin = { "host" => "localhost", "protocol" => "https", "port" => 3443 }

    assert_equal expected_origin, configuration.fetch("routes")
    assert_equal expected_origin, configuration.fetch("mailer")
    assert_equal true, configuration.fetch("assume_ssl")
    assert_equal true, configuration.fetch("force_ssl")
  end

  # The port is carried even when the origin omits it: without it Rails fills
  # the port from the untrusted request Host, and a device-flow or invitation
  # link would carry an attacker-chosen port. Route helpers normalize the
  # explicit default back out of the rendered URL.
  test "an origin without a port still carries its scheme default" do
    configuration = boot_configuration(environment: "production", base_url: "https://nexus.example")

    assert_equal(
      { "host" => "nexus.example", "protocol" => "https", "port" => 443 },
      configuration.fetch("routes")
    )
  end

  test "direct mode leaves request routes unpinned in both environments" do
    development = boot_configuration(environment: "development", base_url: "")
    production = boot_configuration(environment: "production", base_url: "")

    assert_equal({}, development.fetch("routes"))
    assert_equal(
      { "host" => "localhost", "port" => 3210 },
      development.fetch("mailer")
    )
    assert_equal({}, production.fetch("routes"))
    assert_nil production.fetch("mailer")
    assert_equal false, production.fetch("assume_ssl")
    assert_equal false, production.fetch("force_ssl")
  end

  test "both environments reject invalid origins with one operator-facing error" do
    assert_boot_rejected(environment: "development", base_url: "ftp://nexus.example.com")
    assert_boot_rejected(environment: "production", base_url: "https:///missing-host")
  end

  private

    def boot_configuration(environment:, base_url:)
      stdout, stderr, status = run_boot(environment:, base_url:)

      assert status.success?, "Rails #{environment} boot failed:\n#{stderr}\n#{stdout}"
      output = stdout.lines.find { |line| line.start_with?(OUTPUT_PREFIX) }
      assert output, "Rails #{environment} boot returned no configuration:\n#{stdout}"

      JSON.parse(output.delete_prefix(OUTPUT_PREFIX))
    end

    def assert_boot_rejected(environment:, base_url:)
      stdout, stderr, status = run_boot(environment:, base_url:)
      output = stdout + stderr

      assert_not status.success?, "Rails #{environment} unexpectedly booted"
      assert_equal 1, output.scan(ERROR_MESSAGE).length
      assert_not_includes output, "URI::InvalidURIError"
      assert_no_match(/spec \d/i, output)
    end

    def run_boot(environment:, base_url:)
      variables = {
        "BASE_URL" => base_url,
        "PORT" => "3210",
        "RAILS_ASSUME_SSL" => nil,
        "RAILS_ENV" => environment,
        "RAILS_FORCE_SSL" => nil,
        "RACK_ENV" => environment,
        "SECRET_KEY_BASE_DUMMY" => "1",
      }

      Open3.capture3(
        variables,
        RbConfig.ruby,
        "-e",
        BOOT_SCRIPT,
        chdir: Rails.root.to_s
      )
    end
end
