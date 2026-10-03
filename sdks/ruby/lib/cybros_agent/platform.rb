module CybrosAgent
  # Human session and account administration resources. Their credentials
  # belong to the Platform API; no member or executor resources live here.
  module Platform
    Session = Data.define(:public_id, :kind, :expires_at)
    SessionGrant = Data.define(:session, :token, :token_type) do
      include Redacted

      def inspect = redacted(session:, token_type:, hidden: %i[token])
    end
    Member = Data.define(:public_id, :kind, :role)
    Profile = Data.define(:member, :credential_plane)
    CostUnit = Data.define(:cost_unit)
    Retention = Data.define(:execution_details_retention_days)

    module Projections
      include Api::Parsing

      SHAPES = {
        Session => { public_id: :string, kind: :string, expires_at: :string },
        SessionGrant => { session: [:shape, Session], token: :string, token_type: :string },
        Member => { public_id: :string, kind: :string, role: :string },
        Profile => { member: [:shape, Member], credential_plane: :nullable_string },
        CostUnit => { cost_unit: :nullable_string },
        Retention => {
          execution_details_retention_days: ->(hash) {
            unless hash.key?("execution_details_retention_days")
              raise Api::MalformedResponse, "expected execution_details_retention_days"
            end
            optional_integer(hash, "execution_details_retention_days")
          },
        },
      }.freeze
    end

    class SessionContext
      include Projections

      def initialize(dispatch:)
        @dispatch = dispatch
      end

      def fetch
        shape(Session, @dispatch.call("/api/v1/session"), "session")
      end

      def revoke
        answer = @dispatch.call("/api/v1/session", method: :delete)
        raise Api::MalformedResponse, "expected revoked session" unless boolean(hash_item(answer, "response"), "revoked")

        nil
      end
    end

    class ProfileContext
      include Projections

      def initialize(dispatch:)
        @dispatch = dispatch
      end

      def fetch
        shape(Profile, @dispatch.call("/api/v1/profile"))
      end
    end

    class CostUnitContext
      include Projections

      def initialize(dispatch:)
        @dispatch = dispatch
      end

      def fetch
        shape(CostUnit, @dispatch.call("/api/v1/admin/account/cost_unit"), "account")
      end

      # Configure-once on the server: the same value is a successful replay;
      # a different value is Conflict. No client-side remembered state decides it.
      def configure(cost_unit)
        answer = @dispatch.call("/api/v1/admin/account/cost_unit", method: :put,
          body: { "account" => { "cost_unit" => cost_unit } })
        shape(CostUnit, answer, "account")
      end
    end

    class RetentionContext
      include Projections

      PATH = "/api/v1/admin/account/retention".freeze

      def initialize(dispatch:)
        @dispatch = dispatch
      end

      def fetch
        shape(Retention, @dispatch.call(PATH), "account")
      end

      # nil disables collection. The server owns positive-integer validation.
      def update(execution_details_retention_days:)
        answer = @dispatch.call(PATH, method: :patch,
          body: { "account" => { "execution_details_retention_days" => execution_details_retention_days } })
        shape(Retention, answer, "account")
      end
    end
  end
end

require_relative "platform/model_providers"
