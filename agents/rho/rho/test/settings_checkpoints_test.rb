require "test_helper"
require "open3"

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

    # Git's commit date owns pruning; the record timestamp describes the same
    # historical capture so this fixture represents ordinary retained history.
    def age_checkpoint(store, record, captured_at)
      environment = {
        "GIT_AUTHOR_NAME" => "rho", "GIT_AUTHOR_EMAIL" => "rho@localhost",
        "GIT_COMMITTER_NAME" => "rho", "GIT_COMMITTER_EMAIL" => "rho@localhost",
        "GIT_AUTHOR_DATE" => captured_at.iso8601, "GIT_COMMITTER_DATE" => captured_at.iso8601,
        "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1",
      }
      message = record.with(captured_at: captured_at.iso8601).message
      commit, error, status = Open3.capture3(environment, "git", "--git-dir", store.path,
        "commit-tree", record.hash, "-F", "-", stdin_data: message)
      assert_predicate status, :success?, error
      _, error, status = Open3.capture3(environment, "git", "--git-dir", store.path,
        "update-ref", "refs/checkpoints/#{record.run_public_id}", commit.strip)
      assert_predicate status, :success?, error
    end
end
