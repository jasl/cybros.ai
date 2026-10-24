require "test_helper"

class SettingsCheckpointsTest < Minitest::Test
  include RhoTest::DaemonHarness

  def test_shortening_retention_prunes_existing_checkpoints_when_settings_are_saved
    project = File.join(@root, "project")
    FileUtils.mkdir_p(project)
    source = File.join(project, "example.rb")
    File.write(source, "old content")
    daemon = boot(root: File.join(@root, "home"), config: Rho::Config.from_hash(
      { "tools_root" => project, "plugins" => { "rho.checkpoints" => { "configuration" => { "retention_days" => 30 } } } }
    ))
    store = daemon.context.environments.zero_checkpoints
    old = store.capture(run_public_id: "old-run")
    age_checkpoint(store, old, Time.now.utc - (10 * 86_400))
    File.write(source, "current content")
    fresh = store.capture(run_public_id: "fresh-run")
    assert_equal 0, store.prune
    assert_equal %w[fresh-run old-run], store.records.map(&:run_public_id).sort

    response = request(daemon, :patch, "/extensions/rho.checkpoints/configuration", token: bearer(daemon),
      body: { operations: [{ op: "set", path: ["retention_days"], value: 1 }] })

    assert_equal "200", response.code, response.body
    assert_equal 1, JSON.parse(response.body).dig("plugin", "configuration", "value", "retention_days")
    current = daemon.context.environments.zero_checkpoints
    assert_equal [fresh.to_row], current.records.map(&:to_row)
    refute current.tree?(old.hash)
    assert_equal "current content", File.read(source)
  end

  private

    def age_checkpoint(store, record, captured_at)
      db = SQLite3::Database.new(File.join(store.path, Rho::Env::Checkpoints::Store::DATABASE_FILE))
      db.execute("UPDATE records SET created_at = ?, message = ? WHERE run = ?",
        [captured_at.to_i, record.with(captured_at: captured_at.iso8601).message, record.run_public_id])
    ensure
      db&.close
    end
end
