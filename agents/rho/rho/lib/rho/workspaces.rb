module Rho
  # Selection is a product preference. Nexus still judges access and dedication.
  module Workspaces
    def self.list(client, dedicated: nil)
      (dedicated.nil? ? [true, false] : [dedicated]).flat_map do |scope|
        rows = []
        after = nil
        loop do
          page = client.workspaces.list(dedicated_to_current_agent: scope, after: after, limit: 100)
          rows.concat(page.items.select { |row| row.state == "active" })
          after = page.next_after
          break if after.nil?
        end
        rows
      end
    end

    def self.fetch(client, public_id)
      row = client.workspaces.fetch(public_id)
      if row.state != "active" || (row.dedicated && !list(client, dedicated: true).any? { |own| own.public_id == public_id })
        return Daemon::Refusal.new(status: 422, code: "workspace_unavailable",
          message: "#{public_id} is not a live workspace this agent can use; `rho workspaces` lists them")
      end
      row
    end
  end
end
