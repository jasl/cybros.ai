module Deployments
  class Progress
    UPDATES_PER_CONNECTION = 10
    STREAM_SECONDS = 10
    UPDATE_INTERVAL = 1

    def initialize(client:, session:, access_token:)
      @client, @session, @access_token = client, session, access_token
    end

    # Observation survives through the updater's receipt, not this request.
    # Bound each stream and recheck the same credential before every delivery.
    def stream(operation_id:, cursor:, initial:)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + STREAM_SECONDS
      UPDATES_PER_CONNECTION.times do |index|
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        result = index.zero? ? initial : @client.log(operation_id: operation_id, cursor: cursor)
        unless authorized?
          yield :error, Nexus::Deployment::Error.new(code: :administrator_required,
            message: I18n.t("deployment.errors.administrator_required"), operation_id: nil)
          break
        end

        if result.success?
          yield :progress, result.data
          cursor = result.data.next_cursor
          break if result.data.operation.status != "running" &&
            (cursor == result.data.operation.log_cursor || result.data.entries.empty?)
        else
          yield :error, result.error
          break
        end
        sleep UPDATE_INTERVAL if index < UPDATES_PER_CONNECTION - 1
      end
    end

    private

      def authorized?
        # A stream must observe later revocation/demotion instead of reusing
        # the request's cached credential rows.
        ActiveRecord::Base.uncached do
          if @session
            current = Session.includes(:user, :identity).find_by(id: @session.id)
            current && current.usable? && !current.identity.password_change_required? &&
              administrator?(current.user)
          elsif @access_token
            current = AccessToken.includes(:refresh_token_family, user: :identity).find_by(id: @access_token.id)
            current && current.platform_usable? && administrator?(current.user)
          else
            false
          end
        end
      end

      def administrator?(user)
        user.human? && user.active? && user.admin?
      end
  end
end
