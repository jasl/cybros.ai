require_relative "../../../nexus/test/test_helper"
require "open3"
require "rake"
require "rbconfig"
require "tmpdir"

class ManualCodexAuthorizationCommandsTest < ActiveSupport::TestCase
  setup do
    @previous_rake = Rake.application
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    @directory = Dir.mktmpdir
    @previous_environment = ENV.to_h.slice("CODEX_AUTH_FILE", "CI")
    ENV.delete("CI")
  end

  teardown do
    Rake.application = @previous_rake
    %w[CODEX_AUTH_FILE CI].each { |key| ENV[key] = @previous_environment[key] }
    FileUtils.remove_entry(@directory)
  end

  test "Nexus tasks do not install the manual commands" do
    output, error, status = Open3.capture3(RbConfig.ruby, "bin/rake", "--prereqs", chdir: Rails.root)

    assert_predicate status, :success?, error
    assert_includes output, "development:seed"
    refute_includes output, "codex_authorization:manual:dev_import"
    refute_includes output, "codex_authorization:manual:start"
  end

  test "every manual command refuses production before file or database access" do
    load_manual_tasks

    Rails.stub(:env, "production".inquiry) do
      File.stub(:exist?, ->(*) { flunk "production must not inspect the auth file" }) do
        assert_no_queries do
          %w[start refresh step status dev_import].each do |command|
            _out, error = capture_io do
              exception = assert_raises(SystemExit) { manual_task(command).execute }
              refute_predicate exception, :success?
            end

            assert_match "development-only", error
          end
        end
      end
    end
  end

  test "dev import uses the credential install command and prints no tokens" do
    load_manual_tasks
    ENV["CODEX_AUTH_FILE"] = File.join(@directory, "auth.json")
    File.write(ENV.fetch("CODEX_AUTH_FILE"), JSON.generate("tokens" => {
      "access_token" => "manual-access-secret",
      "refresh_token" => "manual-refresh-secret",
      "account_id" => "manual-account-secret",
    }))

    output, error = Rails.stub(:env, "development".inquiry) do
      capture_io { manual_task("dev_import").execute }
    end

    assert_empty error
    projection = JSON.parse(output)
    credential = ModelProviderCredential.find_by!(account: accounts(:cybros), provider_id: "codex_subscription")
    assert_equal "manual-access-secret", credential.secret
    assert_equal "manual-refresh-secret", credential.refresh_secret
    assert_equal({
      "outcome" => "imported",
      "credential_public_id" => credential.public_id,
      "expires_at" => credential.expires_at.iso8601,
      "provider_account_identity_present" => true,
    }, projection)
    refute_match(/manual-(access|refresh|account)-secret/, output)
  end

  test "manual commands refuse CI even in development" do
    load_manual_tasks
    ENV["CI"] = "1"

    Rails.stub(:env, "development".inquiry) do
      assert_no_queries do
        %w[start refresh step status dev_import].each do |command|
          _out, error = capture_io do
            exception = assert_raises(SystemExit) { manual_task(command).execute }
            refute_predicate exception, :success?
          end

          assert_match "not available in CI", error
        end
      end
    end
  end

  private

    def load_manual_tasks
      Rails.application.stub(:load_tasks, nil) do
        load File.expand_path("../codex_authorization.rake", __dir__)
      end
    end

    def manual_task(command)
      Rake::Task["codex_authorization:manual:#{command}"]
    end
end
