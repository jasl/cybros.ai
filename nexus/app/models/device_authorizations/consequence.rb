module DeviceAuthorizations
  # The connection consequence for one human and one program identifier: a
  # pure projection Connect and Consume each re-resolve under their own locks.
  # Every human resolves within their own stewarded agents, administrators included.
  class Consequence
    def self.for(authorization, viewer:)
      member = viewer.stewarded_agents
        .where(
          account_id: authorization.account_id,
          agent_identifier: authorization.agent_identifier
        )
        .take

      new(member)
    end

    attr_reader :member

    def initialize(member)
      @member = member
    end

    def branch
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
