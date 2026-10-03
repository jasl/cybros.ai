require_relative "../../nexus/config/application"

Rails.application.load_tasks

namespace :codex_authorization do
  # Explicit local development entry points for Codex authorization. Every
  # command calls the product's domain seams and prints only the progress
  # needed to continue the flow.
  #
  # It refuses outside development BEFORE touching anything, and it never
  # prints a token, a device handle, or a grant. The step command prints the
  # user code and verification URL needed for the human approval.
  namespace :manual do
    desc "Accept a Codex device-start session and print its secret-free locator"
    task start: :environment do
      refuse_outside_development!

      account = Account.sole
      result = ModelProviders::CodexAuthorization::AcceptSession.call(
        account: account, issuing_user: User.find_by!(role: "owner"), kind: "device_start"
      )
      abort "refused: #{result.outcome}" unless result.accepted?

      puts JSON.pretty_generate(secret_free_session(result.session))
    end

    desc "Accept a token_refresh session over the current credential"
    task refresh: :environment do
      refuse_outside_development!

      result = ModelProviders::CodexAuthorization::AcceptSession.call(
        account: Account.sole, issuing_user: User.find_by!(role: "owner"), kind: "token_refresh"
      )
      abort "refused: #{result.outcome}" unless result.accepted?

      puts JSON.pretty_generate(secret_free_session(result.session))
    end

    desc "Advance one step of a session by public id (performs one provider call at most)"
    task :step, [:public_id] => :environment do |_task, args|
      refuse_outside_development!

      session = ModelProviderOAuthSession.find_by!(public_id: args.fetch(:public_id))
      result = ModelProviders::CodexAuthorization::Advance.call(session: session)
      # The user code is the ONE human-facing value this command may print: it
      # exists to be read aloud to the person approving. Nothing else is.
      puts JSON.pretty_generate(
        secret_free_session(session.reload).merge(
          "step_outcome" => result.outcome.to_s,
          "user_code_for_human" => session.user_code,
          "verification_uri" => session.verification_uri
        ).compact
      )
    end

    desc "Print the current session/credential projection (reads only; writes nothing)"
    task status: :environment do
      refuse_outside_development!

      puts JSON.pretty_generate(
        ModelProviders::CodexAuthorization::Status.for(account: Account.sole).to_h
      )
    end

    desc "Import CODEX_AUTH_FILE's auth.json as the credential (development only)"
    task dev_import: :environment do
      refuse_outside_development!
      require_relative "codex_authorization/dev_import"

      account = Account.sole
      policy = ModelProviderPolicy.find_by(account: account, provider_id: "codex_subscription")
      unless policy&.enabled?
        ModelProviders::EnableLane.call(
          account: account, provider_id: "codex_subscription",
          expected_lock_version: policy&.lock_version
        )
      end
      result = E2E::Manual::CodexAuthorization::DevImport.call(account: account)
      abort "refused: #{result.outcome}" unless result.outcome == :imported

      credential = result.credential
      puts JSON.pretty_generate(
        "outcome" => "imported",
        "credential_public_id" => credential.public_id,
        "expires_at" => credential.expires_at&.iso8601,
        "provider_account_identity_present" => credential.provider_account_identity.present?
      )
    end
  end

  # This interactive flow needs a person watching and may spend a real
  # subscription approval, so it is deliberately development-only.
  def refuse_outside_development!
    unless Rails.env.development?
      abort "refusing: manual Codex authorization is development-only (env=#{Rails.env})"
    end

    abort "refusing: manual Codex authorization is not available in CI" if ENV["CI"].present?
  end

  # Locator and progress facts only. The device handle, the grant, and every
  # token are absent by construction rather than stripped, so a field added to
  # the session later cannot leak through a forgotten redaction.
  def secret_free_session(session)
    {
      "session_public_id" => session.public_id,
      "kind" => session.kind,
      "state" => session.state,
      "progress" => session.progress,
      "outcome" => session.outcome,
      "semantic_exchange_kind" => session.semantic_exchange_kind,
      "semantic_exchange_ordinal" => session.semantic_exchange_ordinal,
      "poll_interval_seconds" => session.poll_interval_seconds,
      "poll_ordinal_ceiling" => session.poll_ordinal_ceiling,
      "authorization_deadline_at" => session.authorization_deadline_at&.utc&.iso8601,
      "tasks" => session.oauth_tasks.order(:id).map do |task|
        {
          "exchange_kind" => task.exchange_kind,
          "state" => task.state,
          "normalized_status" => task.normalized_status,
          "result_kind" => task.result_kind,
        }
      end,
    }
  end
end
