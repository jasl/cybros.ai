module Workspaces
  # A Human owns what they create; an Agent's Workspace is private, owned
  # by its steward and dedicated under its own identifier.
  class Create
    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(creator:, name:, access_mode: nil, metadata: nil)
      @creator = creator
      @name = name
      @access_mode = access_mode&.to_s
      @metadata = metadata
    end

    def call
      if @creator.human?
        create_for_human
      elsif @creator.agent_member?
        create_for_agent
      else
        Mutation::Result.blocked(:not_workspace_owner)
      end
    end

    private

      def create_for_human
        if @access_mode && !Workspace.access_modes.key?(@access_mode)
          return Mutation::Result.blocked(:invalid_access_mode)
        end

        # Creation has no Workspace row. The creator lock prevents remove-first
        # from leaving a live Workspace owned by a removed Human; suspension may
        # fall on either side and the final status gates later access.
        @creator.with_lock do
          if @creator.active?
            insert(owner: @creator, access_mode: @access_mode, agent_identifier: nil)
          else
            Mutation::Result.blocked(:not_workspace_owner)
          end
        end
      end

      def create_for_agent
        if @access_mode && @access_mode != "private"
          return Mutation::Result.blocked(:invalid_access_mode)
        end
        # Agent first, then its current steward: removal-first cannot leave
        # a removed Human as the new owner. Reassignment-first selects the
        # new steward; create-first validly freezes the old one.
        @creator.with_lock do
          steward = User.where(id: @creator.steward_id).lock.first
          if @creator.active? && steward&.active? && @creator.steward_live?
            insert(
              owner: steward,
              access_mode: :private,
              agent_identifier: @creator.agent_identifier
            )
          else
            Mutation::Result.blocked(:not_workspace_owner)
          end
        end
      end

      def insert(owner:, access_mode:, agent_identifier:)
        workspace = @creator.account.workspaces.new(
          creator: @creator,
          owner: owner,
          name: @name,
          agent_identifier: agent_identifier,
          metadata: @metadata.nil? ? {} : @metadata,
        )
        workspace.access_mode = access_mode if access_mode

        if workspace.save
          Mutation::Result.done(:created, workspace)
        else
          Mutation::Result.invalid(workspace)
        end
      end
  end
end
