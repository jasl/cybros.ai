require "test_helper"
require "tmpdir"
require "fileutils"

class TelegramLegacyStateTest < Minitest::Test
  PROFILE_A = "019f08b0-0000-7000-8000-000000000001".freeze
  PROFILE_B = "019f08b0-0000-7000-8000-000000000002".freeze

  class InterruptedStore < TelegramStateSupport::Store
    attr_accessor :interruption

    def create(**attributes)
      failure, @interruption = @interruption, nil
      raise Interrupt, "process stopped before create" if failure == :before

      row = super
      if failure == :after
        raise Interrupt, "process stopped after create"
      elsif failure == :unknown
        @offline = true
        raise CybrosAgent::TransportError, "response lost"
      end
      row
    end

    def list(**)
      if @offline
        @offline = false
        raise CybrosAgent::TransportError, "confirmation unavailable"
      end
      super
    end
  end

  def setup
    @directory = Dir.mktmpdir("rho-telegram-migration")
    @home = Rho::Home.resolve(base_url: "https://nexus.example", root: @directory)
    @legacy_path = File.join(@directory, "telegram", "state.json")
    @legacy = { "bot_id" => "42", "offset" => 100, "pending_update" => { "update" => { "update_id" => 101 } },
      "routes" => {}, "deliveries" => { "old" => { "status" => "pending", "text" => "Profile A only" } } }
    @store_a, @store_b = InterruptedStore.new, TelegramStateSupport::Store.new
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_import_is_claimed_by_one_profile_and_its_backup_never_seeds_another
    source = write_legacy
    first = state(PROFILE_A, @store_a).read
    assert_equal 100, first.fetch("offset")
    assert_equal @legacy.fetch("pending_update"), first.fetch("pending_update")
    refute_path_exists @legacy_path
    refute_path_exists migration_path(PROFILE_A)
    assert_equal source, File.binread(imported_path(PROFILE_A))

    second = state(PROFILE_B, @store_b).read
    assert_nil second.fetch("offset")
    assert_nil second["pending_update"]
    assert_empty second.fetch("deliveries")
    assert_empty @store_b.rows
    assert_equal source, File.binread(imported_path(PROFILE_A))
  end

  def test_an_existing_nexus_entry_retires_the_unowned_source_without_overwriting_database_state
    source = write_legacy
    @store_a.create(namespace: "rho.telegram", key: "state", value: { "bot_id" => "42", "offset" => 200 },
      idempotency_key: "existing")
    assert_equal 200, state(PROFILE_A, @store_a).read.fetch("offset")
    assert_equal 1, @store_a.writes.length
    assert_equal source, File.binread(imported_path(PROFILE_A))
    assert_nil state(PROFILE_B, @store_b).read.fetch("offset")
  end

  def test_interrupted_imports_resume_only_for_the_original_profile
    %i[before after unknown].each do |failure|
      source = write_legacy
      @store_a = InterruptedStore.new
      @store_a.interruption = failure
      error = failure == :unknown ? CybrosAgent::TransportError : Interrupt
      assert_raises(error) { state(PROFILE_A, @store_a).read }
      assert_equal source, File.binread(migration_path(PROFILE_A))
      refute_path_exists @legacy_path
      refute_path_exists imported_path(PROFILE_A)

      other = state(PROFILE_B, @store_b).read
      assert_nil other.fetch("offset")
      assert_empty @store_b.rows
      assert_equal source, File.binread(migration_path(PROFILE_A))

      resumed = state(PROFILE_A, @store_a).read
      assert_equal 100, resumed.fetch("offset")
      assert_equal @legacy.fetch("pending_update"), resumed.fetch("pending_update")
      assert_equal 1, @store_a.writes.length
      assert_equal source, File.binread(imported_path(PROFILE_A))
      refute_path_exists migration_path(PROFILE_A)
      File.unlink(imported_path(PROFILE_A))
    end
  end

  def test_an_installation_without_a_legacy_source_creates_no_local_business_files
    first = state(PROFILE_A, @store_a)
    first.bind(42)
    first.consumed(100)
    state(PROFILE_B, @store_b).bind(42)
    assert_empty Dir.children(@directory)
    assert_equal 101, state(PROFILE_A, @store_a).read.fetch("offset")
    assert_nil state(PROFILE_B, @store_b).read.fetch("offset")
  end

  private

    def state(id, store)
      migration = Rho::IngressTelegram::LegacyState.new(home: @home, user_public_id: id)
      document = Rho::StoreDocument.new(store: -> { store }, namespace: "rho.telegram", key: "state",
        initial: migration.method(:call))
      Rho::IngressTelegram::State.new(store: document, migration: migration)
    end

    def write_legacy
      Rho::StateFile.new(@legacy_path).write(@legacy)
      File.binread(@legacy_path)
    end

    def migration_path(id) = File.join(@directory, "telegram", "state.#{id}.migrating.json")
    def imported_path(id) = File.join(@directory, "telegram", "state.#{id}.imported.json")
end
