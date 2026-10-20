require "test_helper"
require "rho/until/scanner"

class UntilScannerTest < Minitest::Test
  Page = Data.define(:items, :next_after)
  Candidate = Data.define(:public_id, :workspace_public_id, :conversation_public_id, :turn_public_id)
  Client = Data.define(:work, :read) do
    def workspace(id) = Workspace.new(id: id, read: read)
  end
  Workspace = Data.define(:id, :read) do
    def conversation(id) = Conversation.new(public_id: id, read: read)
  end
  Conversation = Data.define(:public_id, :read) do
    def store_entries = self
    def list(**)
      read.call(public_id)
      Page.new(items: [], next_after: nil)
    end
  end
  Work = Data.define(:fetch) do
    def run_candidates(**query) = fetch.call(**query)
  end

  def test_empty_windows_reach_the_tail_and_other_principals_progress_during_retry
    clock = 0.0
    requests, reads, sleeps = [], [], []
    retried = false
    work = Work.new(fetch: ->(agent_public_id:, after:) {
      page = after ? Integer(after) : 0
      requests << [agent_public_id, page]
      clock += 0.002
      if agent_public_id == "a" && page == 1 && !retried
        retried = true
        raise CybrosAgent::TransportError, "temporary"
      end
      last = agent_public_id == "a" ? 799 : 4
      items = page == last ? [Candidate.new(public_id: "run-#{agent_public_id}", workspace_public_id: "w",
        conversation_public_id: "c-#{agent_public_id}", turn_public_id: "t")] : []
      Page.new(items: items, next_after: page == last ? nil : (page + 1).to_s)
    })
    client = Client.new(work: work, read: ->(id) { reads << id })
    Rho::Until::Scanner.new(client: client, owner_public_id: "owner", agent_public_ids: %w[a b],
      timeout_seconds: 30, active: -> { true }, clock: -> { clock },
      sleeper: ->(seconds) { sleeps << seconds; clock += seconds }).call

    assert_equal %w[c-b c-a], reads, "the other principal reaches its tail during the retry delay"
    assert_equal [1, 1], requests.select { |agent, page| agent == "a" && page == 1 }.map(&:last)
    assert_equal (0..799).to_a, requests.select { |agent, _| agent == "a" }.map(&:last).uniq
    assert_operator clock, :<, 20, "800 windows yield briefly; they do not wait for maintenance ticks"
    assert sleeps.all? { |seconds| seconds <= 30 }
  end

  def test_a_failed_candidate_retries_in_place_and_authorization_loss_stops_the_scan
    requests, reads = [], []
    active = true
    work = Work.new(fetch: ->(**query) {
      requests << query
      Page.new(items: %w[first second].map { |id| Candidate.new(public_id: id, workspace_public_id: "w",
        conversation_public_id: id, turn_public_id: "t") }, next_after: "next")
    })
    client = Client.new(work: work, read: ->(id) {
      reads << id
      raise CybrosAgent::TransportError, "temporary" if reads.length == 1

      active = false
    })
    clock = 0.0
    Rho::Until::Scanner.new(client: client, owner_public_id: "owner", agent_public_ids: ["a"],
      timeout_seconds: 30, active: -> { active }, clock: -> { clock },
      sleeper: ->(seconds) { clock += seconds }).call

    assert_equal %w[first first], reads
    assert_equal 1, requests.length, "the failed row keeps its page; revocation prevents the next row"
  end
end
