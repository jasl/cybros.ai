module CybrosAgent
  module Platform
    Authorization = Data.define(:provider_id, :state, :expires_at, :session)
    AuthorizationSession = Data.define(:public_id, :kind, :state, :progress, :outcome,
      :expires_at, :verification_uri, :user_code, :owned_by_current_user) do
      include Redacted

      def inspect = redacted(public_id:, kind:, state:, progress:, outcome:, expires_at:, owned_by_current_user:,
        hidden: %i[user_code verification_uri])
    end

    module ProviderAuthorizationProjections
      include Api::Parsing

      SHAPES = {
        AuthorizationSession => {
          public_id: :string, kind: :string, state: :string, progress: :string,
          outcome: :nullable_string, expires_at: :nullable_string,
          verification_uri: :nullable_string, user_code: :nullable_string,
          owned_by_current_user: :boolean,
        },
        Authorization => {
          provider_id: :string, state: :string, expires_at: :nullable_string,
          session: [:optional_shape, AuthorizationSession],
        },
      }.freeze
    end

    class ProviderAuthorizationContext
      include ProviderAuthorizationProjections
      include Api::WorkspaceProjections

      def initialize(dispatch:, path:)
        @dispatch = dispatch
        @path = path
      end

      def session(public_id)
        AuthorizationSessionContext.new(dispatch: @dispatch, path: "#{@path}/sessions/#{path_segment(public_id, "public_id")}")
      end

      def fetch
        shape(Authorization, @dispatch.call(@path), "authorization")
      end

      # A start is never retried. Recover an uncertain response with fetch;
      # restart explicitly replaces the pending ceremony.
      def start(restart: false)
        answer = @dispatch.call(@path, method: :post,
          body: { "command" => { "restart" => restart } }, success: 202)
        shape(AuthorizationSession, answer, "authorization_session")
      end

      def clear
        shape(Authorization, @dispatch.call(@path, method: :delete), "authorization")
      end
    end

    class AuthorizationSessionContext
      include ProviderAuthorizationProjections

      def initialize(dispatch:, path:)
        @dispatch = dispatch
        @path = path
      end

      def fetch
        shape(AuthorizationSession, @dispatch.call(@path), "authorization_session")
      end
    end
  end
end
