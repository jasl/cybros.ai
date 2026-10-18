require "test_helper"
require "support/oauth_world"

# THE STORE: one real `Rho::StateFile` per
# server under the home — the round trip, the URL rule, the registration
# kept through `save_tokens(nil)`, the pre-registered overlay, the
# read-only view, the live secret set, the stamp, `pending_scope`, the
# refusal of a 0644 file, and a `PublishedError` keeping the pair.
class OauthStorageTest < Minitest::Test
  include McpTest::OauthWorld

  TOKENS = { "access_token" => "at-first-0123456789", "refresh_token" => "rt-first-0123456789", "token_type" => "Bearer",
             "expires_in" => 3600, "scope" => "fx:read", "issuer" => "https://as.example/oauth" }.freeze
  REGISTRATION = { "client_id" => "dcr-1", "token_endpoint_auth_method" => "none", "issuer" => "https://as.example/oauth" }.freeze

  def setup
    @root = File.realpath(Dir.mktmpdir("rho-mcp-store"))
    @home = McpTest::OauthWorld::Home.new(root: @root)
    @base = "https://mcp.example.com"
    @now = McpTest::OauthWorld::FROZEN_NOW
    @clock = -> { @now }
    @log = []
    log = @log
    @logger = Object.new
    %i[debug info warn error].each { |level| @logger.define_singleton_method(level) { |event, **f| log << [level, event, f] } }
    @row = oauth_row
    @storage = storage_for(@row)
  end

  def teardown
    FileUtils.remove_entry(@root) if File.directory?(@root)
  end

  def test_a_row_with_no_home_or_no_oauth_gets_no_storage
    assert_nil Rho::Mcp::Oauth.storage_for(@row, home: nil)
    assert_nil Rho::Mcp::Oauth.storage_for(@row, home: Struct.new(:root).new(@root)), "a host without the directory"
    bearer = oauth_row(headers: { "Authorization" => "Bearer ${FX_TOKEN}" })
    assert_nil Rho::Mcp::Oauth.storage_for(bearer, home: @home), "the static-bearer door has no store"
  end

  def test_the_round_trip_keeps_the_gems_hashes_verbatim_and_stamps_issued_at
    assert_nil @storage.tokens
    assert_nil @storage.client_information
    assert_equal :needs_login, @storage.status.state
    assert_equal "no tokens", @storage.status.reason

    @storage.save_client_information(REGISTRATION)
    @storage.save_tokens(TOKENS)
    assert_equal TOKENS, @storage.tokens
    assert_equal REGISTRATION, @storage.client_information
    file = credential_path
    assert_equal "0600", format("%04o", File.stat(file).mode & 0o777)
    assert_equal "0700", format("%04o", File.stat(File.dirname(file)).mode & 0o777)
    written = document
    assert_equal "#{@base}/mcp", written.fetch("url")
    assert_equal "2027-01-15T08:00:00Z", written.fetch("issued_at")
    assert_equal @now, @storage.issued_at
    status = @storage.status
    assert_equal [:logged_in, nil, "https://as.example/oauth", "fx:read", "2027-01-15T08:00:00Z", true],
      [status.state, status.reason, status.issuer, status.scope, status.issued_at, status.refresh_token]
    assert_includes @log, [:info, "mcp.oauth.refreshed", { server: "fxo" }], "the daemon's storage logs a save"
  end

  # The file is the ONE parse boundary: a member a hand edit left as a
  # non-object reads as absent everywhere, and a read rewrites nothing.
  def test_a_hand_edited_non_object_member_reads_as_absent
    @storage.file.write("url" => @row.url, "tokens" => "pasted by hand", "client_information" => ["dcr-1"], "issued_at" => "2027-01-15T08:00:00Z")
    before = File.read(credential_path)
    assert_nil @storage.tokens
    assert_nil @storage.client_information
    assert_equal [:needs_login, "no tokens"], [@storage.status.state, @storage.status.reason]
    assert_nil @storage.read_only.tokens
    assert_equal before, File.read(credential_path), "a read rewrites nothing"
  end

  def test_tokens_are_nil_past_the_url_rule_and_status_says_why
    @storage.save_tokens(TOKENS)
    moved = oauth_row(url: "#{@base}/v2/mcp")
    storage = storage_for(moved)
    assert_nil storage.tokens, "tokens minted for one URL never ride to another"
    status = storage.status
    assert_equal :needs_login, status.state
    assert_equal "logged in for #{@base}/mcp, the row now names #{@base}/v2/mcp", status.reason
  end

  def test_clearing_the_tokens_keeps_the_registration_and_drops_the_stamp
    @storage.save_client_information(REGISTRATION)
    @storage.save_tokens(TOKENS)
    @storage.record_optional(true)
    @storage.save_tokens(nil)
    assert_nil @storage.tokens
    assert_equal REGISTRATION, @storage.client_information, "the gem's storage contract: the registration outlives the tokens"
    refute document.key?("issued_at")
    refute document.key?("optional"), "the optional mark goes with the tokens"
    assert_equal "no tokens", @storage.status.reason
    refute @storage.status.optional
  end

  # THE OPTIONAL-AUTHORIZATION MARK: the verb records after the flow saved
  # the pair that the server answered anonymously too (`Challenge.published`);
  # the status carries it, a refresh keeps it, the read-only view reads it.
  def test_the_optional_mark_is_recorded_carried_by_the_status_and_kept_through_a_refresh
    @storage.save_tokens(TOKENS)
    refute @storage.status.optional, "absent is a login the server asked for"
    @storage.record_optional(true)
    assert_equal true, document.fetch("optional")
    assert @storage.status.optional
    assert @storage.read_only.status.optional
    assert_equal :logged_in, @storage.status.state
    @storage.save_tokens(TOKENS.merge("access_token" => "at-second-0123456789"))
    assert @storage.status.optional, "a refresh keeps the mark"
    @storage.record_optional(false)
    refute document.key?("optional")
    refute @storage.status.optional
  end

  # The pre-registered client OVERLAYS in memory: the file holds the gem's
  # issuer stamp alone, never the configured id.
  def test_a_configured_client_id_is_overlaid_and_only_its_stamp_persists
    row = oauth_row(oauth: { "client_id" => "rho-at-acme" })
    storage = storage_for(row)
    assert_equal({ "client_id" => "rho-at-acme", "token_endpoint_auth_method" => "none" }, storage.client_information,
      "configured, unstamped: the gem binds it on first use")
    storage.save_client_information("client_id" => "rho-at-acme", "token_endpoint_auth_method" => "none",
      "issuer" => "https://as.example/oauth")
    assert_equal({ "issuer" => "https://as.example/oauth" }, document.fetch("client_information"), "the stamp alone")
    assert_equal({ "client_id" => "rho-at-acme", "token_endpoint_auth_method" => "none", "issuer" => "https://as.example/oauth" },
      storage.client_information)
    storage.save_client_information(nil)
    refute document.key?("client_information"), "nil drops the stamp"
    assert_equal({ "client_id" => "rho-at-acme", "token_endpoint_auth_method" => "none" }, storage.client_information)
  end

  def test_delete_unlinks_the_file_whole
    @storage.save_client_information(REGISTRATION)
    @storage.save_tokens(TOKENS)
    @storage.delete!
    refute File.exist?(credential_path)
    assert_nil @storage.tokens
    assert_nil @storage.client_information
    @storage.delete!
  end

  def test_a_file_readable_by_others_is_a_credential_file_fault_never_a_login
    @storage.save_tokens(TOKENS)
    File.chmod(0o644, credential_path)
    error = assert_raises(Rho::Mcp::Oauth::CredentialFile) { @storage.tokens }
    assert_equal "credential file mcp/credentials/fxo.json must be private (mode 0600), got 0644", error.message
    status = @storage.status
    assert_equal :credential_file, status.state
    assert_equal error.message, status.reason
    assert_kind_of Rho::Mcp::Error, error
  end

  # The StateFile's own rule: a published document whose directory entry
  # could not be flushed is written — the pair is kept in memory, logged
  # once, never retried.
  def test_a_published_error_keeps_the_pair_in_memory_logs_once_and_never_retries
    file = Rho::StateFile.new(credential_path)
    writes = []
    file.define_singleton_method(:write) do |document|
      writes << document
      raise Rho::StateFile::PublishedError, "state file x is published but its directory entry could not be flushed (Errno::EIO); the document is written — do not retry"
    end
    storage = Rho::Mcp::Oauth::Storage.new(file: file, row: @row, log: @logger, clock: @clock)
    storage.save_tokens(TOKENS)
    assert_equal TOKENS, storage.tokens, "the new pair stays in memory"
    assert_equal :logged_in, storage.status.state
    storage.save_client_information(REGISTRATION)
    assert_equal 2, writes.length, "each save is one write; none is retried"
    assert_equal 1, @log.count { |entry| entry[1] == "mcp.oauth.store_unflushed" }
    assert_equal [:warn, "mcp.oauth.store_unflushed", { server: "fxo" }], @log.find { |entry| entry[1] == "mcp.oauth.store_unflushed" }
  end

  def test_secret_values_accumulate_across_a_rotation_and_never_read_the_file
    @storage.save_tokens(TOKENS)
    rotated = TOKENS.merge("access_token" => "at-second-0123456789", "refresh_token" => "rt-second-0123456789")
    @storage.save_tokens(rotated)
    assert_equal %w[at-first-0123456789 rt-first-0123456789 at-second-0123456789 rt-second-0123456789], @storage.secret_values
    assert_predicate @storage.secret_values, :frozen?
    fresh = storage_for(@row)
    assert_empty fresh.secret_values, "a fresh storage has read nothing"
    fresh.tokens
    assert_equal %w[at-second-0123456789 rt-second-0123456789], fresh.secret_values, "a read remembers what it saw"
  end

  def test_the_read_only_view_answers_no_refresh_token_and_refuses_every_save
    @storage.save_client_information(REGISTRATION)
    @storage.save_tokens(TOKENS)
    view = @storage.read_only
    assert_predicate view, :read_only?
    assert_equal TOKENS.except("refresh_token"), view.tokens
    assert_equal REGISTRATION, view.client_information
    assert_equal @storage.secret_values, view.secret_values
    assert_equal :logged_in, view.status.state
    error = assert_raises(Rho::Mcp::Error) { view.save_tokens(nil) }
    assert_equal "this verb does not write credentials", error.message
    assert_raises(Rho::Mcp::Error) { view.save_client_information(nil) }
    assert_nil view.record_pending_scope(%w[fx:read fx:write]), "a step-up seen through the view records nothing"
    assert_nil @storage.pending_scope
    assert_equal TOKENS, @storage.tokens, "nothing was cleared"
    assert_same view, view.read_only
  end

  def test_pending_scope_is_recorded_cleared_and_read_as_the_step_up_reason
    @storage.save_tokens(TOKENS)
    assert_nil @storage.pending_scope
    @storage.record_pending_scope(%w[fx:read fx:write])
    assert_equal "fx:read fx:write", @storage.pending_scope
    status = @storage.status
    assert_equal :needs_login, status.state
    assert_equal "the server now requires scope fx:write; the login asks for fx:read fx:write", status.reason
    assert_equal TOKENS, @storage.tokens, "the tokens are still valid and still answered"
    @storage.clear_pending_scope!
    assert_nil @storage.pending_scope
    assert_equal :logged_in, @storage.status.state
  end
end
