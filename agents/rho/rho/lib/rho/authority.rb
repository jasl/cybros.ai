require "cybros_agent"

module Rho
  class Authority
    # `unknown` is not a hedge: Nexus being unreachable says nothing about our
    # authority, and reporting a plane dead on that evidence would send a human
    # to redo a ceremony they do not need.
    PLANES = %i[member executor_transport].freeze

    def initialize(oauth:, base_url:, transport: nil, expected_identity: nil)
      @oauth = oauth
      @base_url = base_url
      @transport = transport
      @expected_identity = expected_identity
    end

    def check
      states = PLANES.to_h { |plane| [plane, probe(plane)] }
      { planes: states, lost: @lost, member_handle: @member_handle }.compact
    end

    private

      def probe(plane)
        credential = credential_for(plane)
        return :absent if credential.nil?

        # Read BEFORE the call: the counter exists to notice a rotation that
        # happened DURING this probe, and a value read after the refusal has
        # already absorbed it.
        rotation = @oauth.rotation if @oauth.refreshable?
        result = call(plane, credential)
        verify_expected_identity(plane, result)
        :live
      rescue CybrosAgent::DeviceFlow::AuthorizationLostError, CybrosAgent::Credentials::ConnectionSuperseded
        # Terminal loss arrives here, out of the proactive refresh inside
        # `credential_for` — the only thing on this path that rotates at all.
        @lost = true
        :unauthorized
      rescue CybrosAgent::Api::Unauthorized
        adopted = adopt_current_rotation(plane, rotation)
        adopted.nil? ? :unauthorized : accepted?(plane, adopted)
      rescue CybrosAgent::Api::Error, CybrosAgent::TransportError
        # Nexus being unreachable or broken says nothing about our authority.
        # Reporting `unauthorized` here would send a human to redo a ceremony
        # they do not need.
        :unknown
      end

      def accepted?(plane, credential)
        result = call(plane, credential)
        verify_expected_identity(plane, result)
        :live
      rescue CybrosAgent::Api::Unauthorized
        :unauthorized
      rescue CybrosAgent::Api::Error, CybrosAgent::TransportError
        :unknown
      end

      # A probe SPENDS NOTHING. It used to rotate on a 401 — one reactive
      # retry, justified by a supposedly stale credential. That was wrong: one
      # RHO_HOME has one writer, and the boot lock enforces it.
      # And the credential in our hand was already refreshed if it needed to
      # be, because `credential_for` runs the gem's proactive `ensure_fresh`
      # before returning — so a 401 arrives on a credential that is BY
      # CONSTRUCTION not stale. Rotating again could only spend a single-use
      # token to be told the same thing twice, and since `/status` calls this
      # on every poll, a revoked address spent one rotation per poll forever.
      #
      # Nexus answers every refusal with one undifferentiated 401, so a refusal can never say which repair to attempt. The answer is
      # to attempt none: repair belongs to whoever owns the credential's
      # lifecycle — proactively in the gem, on schedule in Renewal — never to
      # the component that merely observes it.
      #
      # What remains is free. The renewal thread may have rotated between our
      # read and the refusal, leaving the credential in our hand one moment
      # stale while the live one is already on disk. Adopting it spends
      # nothing.
      def adopt_current_rotation(plane, rotation)
        return nil unless @oauth.refreshable? && @oauth.rotation > rotation.to_i

        credential_for(plane)
      rescue CybrosAgent::Error
        nil
      end

      def credential_for(plane)
        return nil if @oauth.nil?

        case plane
        when :member then @oauth.member_credential
        when :executor_transport then @oauth.executor_credential
        else raise ArgumentError, "unknown credential plane #{plane}"
        end
      rescue CybrosAgent::Credentials::PlaneUnavailable
        nil
      end

      def call(plane, credential)
        if plane == :member
          CybrosAgent::Client.new(base_url: @base_url, credential: credential, transport: @transport)
            .profile.fetch.tap { |profile| @member_handle = profile.member.handle }
        else
          CybrosAgent::ExecutorClient.new(
            base_url: @base_url, credential: credential, transport: @transport
          ).executor
        end
      end

      # A pointer locates the stored vault; it does not prove the credential
      # inside still names that pointer. Every boot probes every plane, and a
      # live answer that names another user or executor is corruption/copying,
      # not a new identity to adopt silently. Refused or unknown planes remain
      # ordinary per-plane authority facts and are handled above.
      def verify_expected_identity(plane, result)
        return if @expected_identity.nil?

        actual, expected =
          case plane
          when :member then [result.member.public_id, @expected_identity.user_public_id]
          when :executor_transport then [result.executor.public_id, @expected_identity.executor_public_id]
          else raise ArgumentError, "unknown credential plane #{plane}"
          end
        return if actual == expected

        raise StoredConnectionError,
          "the stored #{plane} credential names #{actual.inspect}, expected #{expected.inspect}"
      end
  end
end
