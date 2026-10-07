module DeviceAuthorizations
  # The connection consequence for one human and one program identifier: a
  # pure projection Connect and Consume each re-resolve under their own locks.
  # An instance identifier cannot be claimed by a different Human.
  class Consequence
    def self.for(authorization, viewer:)
      member = authorization.account.users.where(kind: :agent)
        .where(
          account_id: authorization.account_id,
          agent_identifier: authorization.agent_identifier
        )
        .take

      new(member, viewer: viewer)
    end

    attr_reader :member

    def initialize(member, viewer:)
      @member = member
      @viewer = viewer
    end

    def bound_elsewhere?
      member && member.steward_id != @viewer.id
    end

    def branch
      return :bound_elsewhere if bound_elsewhere?

      case member&.status
      when "active" then :reconnect
      when "removed" then :restore_and_reconnect
      when nil then :create
      else
        raise ArgumentError, "unsupported Agent profile status: #{member.status.inspect}"
      end
    end
  end
end
