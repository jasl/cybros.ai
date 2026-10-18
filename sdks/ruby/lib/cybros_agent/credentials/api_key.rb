require "securerandom"

module CybrosAgent
  module Credentials
    # Static keys carry independent plane authority. They have no expiry,
    # refresh lineage or rotation; the kernel validates each presented key.
    class APIKey
      Document = Data.define(:connection, :access_token, :executor_access_token, :platform_access_token) do
        def self.from_h(document, where:)
          parsed = new(
            connection: Credentials::Document.text(document, "connection", "#{where} has no connection"),
            access_token: Credentials::Document.optional_text(document, "access_token", "#{where} holds an unusable access token"),
            executor_access_token: Credentials::Document.optional_text(
              document, "executor_access_token", "#{where} holds an unusable executor access token"
            ),
            platform_access_token: Credentials::Document.optional_text(
              document, "platform_access_token", "#{where} holds an unusable platform access token"
            )
          )
          unless parsed.member_plane? || parsed.executor_plane? || parsed.platform_plane?
            raise StoreError, "#{where} has no API key"
          end

          parsed
        end

        def authentication_kind = "api_key"
        def member_plane? = !access_token.nil?
        def executor_plane? = !executor_access_token.nil?
        def platform_plane? = !platform_access_token.nil?

        def to_h
          {
            "version" => Credentials::Document::VERSION,
            "authentication_kind" => authentication_kind,
            "connection" => connection,
            "access_token" => access_token,
            "executor_access_token" => executor_access_token,
            "platform_access_token" => platform_access_token,
          }.compact
        end

        def persist(store)
          store.write(to_h)
          nil
        rescue Store::Published
          nil
        rescue StandardError => error
          raise StoreError, "API keys could not be written to #{store.description} (#{error.class})", cause: nil
        end
      end

      def self.issue(authority:, store:, access_token: nil, executor_access_token: nil, platform_access_token: nil)
        document = Document.from_h(
          { "connection" => SecureRandom.uuid, "access_token" => access_token,
            "executor_access_token" => executor_access_token, "platform_access_token" => platform_access_token }.compact,
          where: "API key credentials"
        )
        store.with_lock { document.persist(store) }
        new(authority: authority, store: store, document: document)
      end

      def initialize(authority:, store:, document:)
        @authority = authority
        @store = store
        @document = document
      end

      def authentication_kind = "api_key"
      def refreshable? = false
      def member_credential = present("member", @document.access_token)
      def executor_credential = present("executor_transport", @document.executor_access_token)
      def platform_credential = present("platform", @document.platform_access_token)
      def member_plane? = @document.member_plane?
      def executor_plane? = @document.executor_plane?
      def platform_plane? = @document.platform_plane?

      # Each revocation is independently idempotent. A partial failure leaves
      # the complete document available so the caller can retry the operation.
      def revoke
        @store.with_lock do
          Credentials::Document.refuse_if_superseded(@store, connection: @document.connection)
          [@document.access_token, @document.executor_access_token, @document.platform_access_token].compact.each do |token|
            @authority.revoke(token: token)
          end
          @store.delete
        end
        nil
      end

      include Redacted

      def inspect
        redacted(authentication_kind: authentication_kind, member_plane: member_plane?,
          executor_plane: executor_plane?, platform_plane: platform_plane?,
          hidden: %i[access_token executor_access_token platform_access_token])
      end

      private

        def present(plane, credential)
          raise PlaneUnavailable, "this connection has no live #{plane} credential" if credential.nil?

          credential
        end
    end
  end
end
