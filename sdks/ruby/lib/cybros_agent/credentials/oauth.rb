require "securerandom"
require "time"

module CybrosAgent
  module Credentials
    # A connection's credentials, kept fresh and kept durable.
    #
    # Refresh tokens are single-use and rotate on every refresh; presenting
    # one the kernel has already seen revokes every credential of the
    # connection. So a rotated pair is persisted before it is handed to
    # anyone, one process owns rotation, and the store is re-read only to
    # notice an explicit reconnect — never to replace the live pair.
    class OAuth
      # Renewal happens this many seconds before the stated expiry, absorbing
      # clock skew and in-flight latency; a daemon renews earlier on its own.
      EXPIRY_SKEW_SECONDS = 60

      # The persisted document, verified once at the door: a bad file names
      # its field, never its value, because the values are the secrets.
      Document = Data.define(
        :connection, :rotation, :refresh_token, :expires_at, :access_token, :executor_access_token, :platform_access_token
      ) do
        VERSION = 1

        def initialize(platform_access_token: nil, **rest)
          super(**rest, platform_access_token: platform_access_token)
        end

        def self.issued(credentials, connection:, rotation:, now:)
          new(
            connection:, rotation:,
            refresh_token: credentials.refresh_token,
            expires_at: (now + credentials.expires_in).getutc,
            access_token: (credentials.access_token if credentials.member_plane?),
            executor_access_token: (credentials.executor_access_token if credentials.executor_plane?),
            platform_access_token: (credentials.platform_access_token if credentials.platform_plane?)
          )
        end

        # The store's document, or nil when none was ever written.
        def self.read(store)
          document = store.read
          from_h(document, where: "credential store #{store.description}") unless document.nil?
        end

        def self.from_h(document, where:)
          document = Hash.try_convert(document)
          raise StoreError, "#{where} does not contain a credential document" if document.nil?
          raise StoreError, "#{where} is not format version #{VERSION}" unless document["version"] == VERSION

          new(
            connection: text(document, "connection", "#{where} has no connection"),
            rotation: rotation(document, where:),
            refresh_token: text(document, "refresh_token", "#{where} has no refresh token"),
            expires_at: expiry(document, where:),
            access_token: optional_text(document, "access_token", "#{where} holds an unusable access token"),
            executor_access_token: optional_text(
              document, "executor_access_token", "#{where} holds an unusable executor access token"
            ),
            platform_access_token: optional_text(document, "platform_access_token", "#{where} holds an unusable platform access token")
          )
        end

        def self.text(document, field, message)
          value = document.fetch(field).to_str
          raise StoreError, message if value.empty?

          value
        rescue KeyError, NoMethodError, TypeError
          raise StoreError, message
        end

        def self.optional_text(document, field, message)
          text(document, field, message) if document.key?(field)
        end

        def self.rotation(document, where:)
          Integer(document.fetch("rotation"))
        rescue KeyError, ArgumentError, TypeError
          raise StoreError, "#{where} has no rotation counter"
        end

        def self.expiry(document, where:)
          Time.iso8601(document["expires_at"].to_s)
        rescue ArgumentError
          raise StoreError, "#{where} has no usable expiry"
        end
        private_class_method :text, :optional_text, :rotation, :expiry

        def to_h
          {
            "version" => VERSION,
            "connection" => connection,
            "rotation" => rotation,
            "refresh_token" => refresh_token,
            "expires_at" => expires_at.iso8601,
            "access_token" => access_token,
            "executor_access_token" => executor_access_token,
            "platform_access_token" => platform_access_token,
          }.compact
        end

        def member_plane? = !access_token.nil?
        def executor_plane? = !executor_access_token.nil?
        def platform_plane? = !platform_access_token.nil?

        def rotated(credentials, now:) = self.class.issued(credentials, connection:, rotation: rotation + 1, now:)

        # A write that lands but whose durability is unconfirmed is still a
        # persisted document; every other write failure means the same thing
        # to a holder of an already-spent token, so they raise one contract.
        def persist(store)
          store.write(to_h)
        rescue Store::Published
          nil
        rescue StandardError => error
          raise NotDurable,
            "the rotated credential is live but could not be written to #{store.description} " \
            "(#{error.class}: #{Redaction.call(error.message)}); keep using it and do not rotate " \
            "again — a restart will not find it"
        end
      end

      class << self
        # Rehydrate a persisted connection, or nil when none was ever written.
        def load(authority:, store:, clock: -> { Time.now })
          document = Document.read(store)
          new(authority: authority, store: store, clock: clock, document: document) unless document.nil?
        end

        # Persist a freshly connected bundle before anything uses it. The
        # connection id is minted locally so an instance from an earlier
        # ceremony can see it was superseded; publishing takes the same Store
        # lock as rotation so an in-flight old rotation finishes first.
        def issue(credentials:, authority:, store:, clock: -> { Time.now })
          document = Document.issued(credentials, connection: SecureRandom.uuid, rotation: 0, now: clock.call)
          store.with_lock { document.persist(store) }
          new(authority: authority, store: store, clock: clock, document: document)
        end
      end

      def initialize(authority:, store:, clock:, document:)
        @authority = authority
        @store = store
        @clock = clock
        @document = document
        @lost = nil
      end

      # The member credential, renewed first if it is close enough to expiry
      # that a caller would be refused for using it.
      def member_credential = present("member", fresh_document.access_token)

      # This delivery address's transport credential, on the same terms.
      def executor_credential = present("executor_transport", fresh_document.executor_access_token)

      def platform_credential = present("platform", fresh_document.platform_access_token)

      def member_plane? = @document.member_plane?
      def executor_plane? = @document.executor_plane?
      def platform_plane? = @document.platform_plane?
      def expires_at = @document.expires_at
      def rotation = @document.rotation

      # End this lineage on the kernel and forget it (`rho disconnect`): the refresh token is presented to RFC 7009 revocation,
      # which ends the whole family, and the store is emptied under the same
      # lock rotation takes — a revoked secret is not kept. A lineage whose
      # loss is already latched has nothing left to present.
      def revoke
        @store.with_lock do
          @authority.revoke(token: @document.refresh_token) unless @lost
          @store.delete
        end
        nil
      end

      # Force a rotation — the recovery a client runs after a 401 it did not
      # predict. `after:` is the #rotation the refused request used, so a
      # burst of refusals answering one expiry costs one rotation, not one each.
      def refresh(after: nil)
        rotate(force: true, after: after)
        self
      end

      include Redacted

      def inspect
        redacted(rotation:, expires_at: expires_at.iso8601, member_plane: member_plane?,
                 executor_plane: executor_plane?, platform_plane: platform_plane?,
                 hidden: %i[access_token refresh_token platform_access_token])
      end

      private

        # `ensure_fresh` runs before any request is made, so a 401 never
        # arrives on a credential that is stale by this clock.
        def expired? = @clock.call >= (expires_at - EXPIRY_SKEW_SECONDS)

        def fresh_document
          rotate(force: false) if expired?
          @document
        end

        def present(plane, credential)
          raise PlaneUnavailable, "this connection has no live #{plane} credential" if credential.nil?

          credential
        end

        # The store lock is the one synchronization authority for credential
        # mutation in this process; the authority's request timeout bounds it.
        def rotate(force:, after: nil)
          @store.with_lock do
            refuse_if_superseded
            raise @lost if @lost
            return if after && @document.rotation > after
            return unless force || expired?

            # Kills abandon waits and never split an answer from its persist:
            # the mask covers wire-and-commit, and re-opens delivery only at
            # the blocking socket wait, where nothing dispatched means nothing
            # spent (measured: a kill storm severed answers from their persist
            # when the mask opened after `rotate` returned).
            Thread.handle_interrupt(Object => :never) do
              rotated = begin
                Thread.handle_interrupt(Object => :on_blocking) do
                  @authority.rotate(refresh_token: @document.refresh_token)
                end
              rescue DeviceFlow::AuthorizationLostError => error
                # The kernel may already have redeemed this token; presenting
                # it again turns a possibly-recoverable connection into reuse.
                @lost = error
                raise
              end
              @document = @document.rotated(rotated, now: @clock.call)
              @document.persist(@store)
            end
          end
        end

        # A reconnect in this process publishes a new connection document; an
        # old renewal reaching the store afterwards must not overwrite it.
        def refuse_if_superseded
          persisted = Document.read(@store)
          if persisted && persisted.connection != @document.connection
            raise ConnectionSuperseded,
              "#{@store.description} now holds a different connection; this one was superseded by a reconnect"
          end
          nil
        end
    end
  end
end
