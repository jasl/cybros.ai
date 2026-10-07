require "test_helper"
require "rho/store_document"
require "async"

class StoreDocumentTest < Minitest::Test
  Row = Data.define(:public_id, :namespace, :key, :lock_version, :value)
  Page = Data.define(:items, :next_after)

  class Store
    attr_accessor :row, :failure
    attr_reader :writes

    def initialize = @writes = 0
    def list(**) = Page.new(items: [@row].compact, next_after: nil)
    def fetch(id) = @row

    def create(namespace:, key:, value:, **)
      raise CybrosAgent::Api::Conflict.new("key taken", code: "key_taken") if @row

      publish(Row.new(public_id: "entry", namespace: namespace, key: key, lock_version: 0, value: copy(value)))
    end

    def update(id, value:, lock_version:)
      raise CybrosAgent::Api::Conflict.new("stale", code: "stale_object") unless lock_version == @row.lock_version

      publish(@row.with(value: copy(value), lock_version: lock_version + 1))
    end

    private

      def publish(row)
        @writes += 1
        raise CybrosAgent::TransportError, "before commit" if @failure == :before

        @row = row
        raise CybrosAgent::TransportError, "response lost" if @failure == :after

        row
      end

      def copy(value) = JSON.parse(JSON.generate(value))
  end

  def setup
    @store = Store.new
    @document = document
  end

  def test_new_process_reads_the_committed_current_value_and_reads_cannot_change_it
    @document.change { |value| value["offset"] = 7 }
    @document.read["offset"] = 99
    assert_equal 7, document.read.fetch("offset")
    assert_equal 1, @store.writes
  end

  def test_response_lost_after_commit_is_confirmed_without_replaying_the_mutation
    @store.failure = :after
    @document.change { |value| value["delivery"] = "sending" }
    assert_equal "sending", @document.read.fetch("delivery")
    assert_equal 1, @store.writes
  end

  def test_failed_commit_never_publishes_the_proposed_value
    @document.change { |value| value["offset"] = 3 }
    @store.failure = :before
    assert_raises(CybrosAgent::TransportError) { @document.change { |value| value["offset"] = 9 } }
    assert_equal 3, @document.read.fetch("offset")
  end

  def test_competing_writer_is_not_overwritten_or_automatically_retried
    @document.change { |value| value["offset"] = 3 }
    other = document
    other.read
    @document.change { |value| value["offset"] = 4 }
    assert_raises(CybrosAgent::Api::Conflict) { other.change { |value| value["offset"] = 5 } }
    assert_equal 4, other.read.fetch("offset")
    assert_equal 2, @store.writes
  end

  def test_nested_read_is_reentrant_and_another_fiber_waits_for_commit
    @document.change { |value| value["offset"] = 0 }
    observations = []
    Async do |task|
      first = task.async do
        @document.change do |value|
          value["offset"] = @document.read.fetch("offset") + 1
          sleep 0.03
        end
      end
      second = task.async { observations << @document.read.fetch("offset") }
      [first, second].each(&:wait)
    end
    assert_equal [1], observations
  end

  def test_unavailable_nexus_is_not_an_empty_store
    unavailable = Rho::StoreDocument.new(store: -> { raise Rho::ConnectionError, "offline" },
      namespace: "test", key: "state")
    assert_raises(Rho::ConnectionError) { unavailable.read }
  end

  def test_known_rate_rejection_keeps_the_committed_cache_and_does_not_spend_a_confirmation_read
    @document.change { |value| value["offset"] = 3 }
    @store.define_singleton_method(:update) { |*, **| raise CybrosAgent::Api::RateLimited.new(retry_after: 60) }
    @store.define_singleton_method(:list) { |**| raise "Do not immediately reread a spent resource budget" }
    error = assert_raises(CybrosAgent::Api::RateLimited) { @document.change { |value| value["offset"] = 4 } }
    assert_equal 60, error.retry_after
    assert_equal 3, @document.read.fetch("offset")
  end

  private

    def document(**options)
      Rho::StoreDocument.new(store: -> { @store }, namespace: "test", key: "state", **options)
    end
end
