require "test_helper"
require "cgi/escape"
require "fileutils"
require "rho"
require "securerandom"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/rho_daemon"
require "support/secret_hygiene"
require "support/steward_session"

# Scripted proposals prove the public delivery, execution and persistence
# path. They do not measure a model's semantic memory extraction quality.
class RhoMemoryReviewTest < Minitest::Test
  MODEL = "dev/mock-text".freeze
  PATH = "conversation/review.md".freeze

  def setup
    @base_url = E2E.base_url
    @steward = E2E::ActorProvisioning.world(@base_url).rho_steward
    @actor = E2E::StewardSession.actor(base_url: @base_url, human: @steward)
    @root = Dir.mktmpdir("rho-memory-review-e2e")
    @home, @project = File.join(@root, "home"), File.join(@root, "work")
    FileUtils.mkdir_p([@home, @project])
    File.write(File.join(@home, "settings.json"), JSON.generate({ "settings_version" => 1, "plugins" => {}, "api_only" => true }), perm: 0o600)
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home, tools_root: @project)
    @daemon.start
    E2E::Ceremony.confirm(actor: @actor, started: @daemon.start_ceremony, status: -> { @daemon.status })
    @daemon.await("rho never adopted its workspace") { @daemon.status.dig("workspace", "state") == "adopted" }
    @daemon.await_announced(address: "agent")
    @member = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    @workspace = @member.workspace(@daemon.status.dig("workspace", "public_id"))
    @core = Rho::Core.new(home: Rho::Home.resolve(base_url: @base_url, root: @home))
    E2E.enable_dev_lane!
    E2E.hosts.start
  end

  def teardown
    unless passed?
      [@daemon&.log_path, @daemon&.rho_log_path].compact.each do |path|
        warn E2E::SecretHygiene.redact(File.read(path)) if File.file?(path)
      end
    end
    @daemon&.dispose_connection
    @operator&.session&.revoke
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def test_a_completed_reply_is_reviewed_in_a_side_and_forgetting_does_not_erase_the_source
    opened = @core.open_conversation(model: MODEL, directory: @project)
    id = opened.fetch("conversation").fetch("public_id")
    chat = @workspace.conversation(id)
    refute cli_json("memory-review", id, "--json").fetch("enabled")
    assert cli_json("memory-review", id, "enable", "--path", PATH, "--json").fetch("enabled")
    initial = chat.memory.read(PATH)
    answer = JSON.generate("content" => "# Memory\n\nThe release checklist uses a blue marker.\n",
      "summary" => "Verified the release checklist.")
    admitted = @core.say(id, "!mock raw_reply=#{CGI.escape(answer)} -- Verified the release checklist with the blue marker.",
      model: MODEL)
    source = completed_turn(chat, admitted.fetch("run").fetch("public_id"))
    reviewed = settled_review(id, outcome: "updated")
    review_id = reviewed.fetch("run_public_id")
    side = @workspace.conversation(reviewed.fetch("review_conversation_public_id"))
    assert_predicate side.fetch, :side?
    review = completed_run(review_id)
    assert_equal ["model_task"], review.tasks.map(&:kind)
    assert_equal answer, @workspace.runs.run(review_id).task(review.tasks.fetch(0).key).output
    document = chat.memory.read(PATH)
    assert_equal initial.public_id, document.public_id
    assert_operator document.lock_version, :>, initial.lock_version
    assert_includes document.content, "The release checklist uses a blue marker."
    assert_includes document.content, "Past work (#{source.created_at}): Verified the release checklist."
    assert_includes document.content, "conversation #{id}; turn #{source.public_id}; run #{source.active_variant.run_public_id}"
    found = chat.memory.grep(pattern: "Verified the release checklist", path: "conversation/")
    assert_equal PATH, found.fetch("matches").fetch(0).fetch("path")
    recalled = chat.turns.fetch(source.public_id)
    assert_equal answer, recalled.active_variant.content
    assert_equal source.active_variant.run_public_id, recalled.active_variant.run_public_id

    malformed = @core.say(id, "!mock raw_reply=malformed-review-output -- A routine acknowledgement.", model: MODEL)
    completed_turn(chat, malformed.fetch("run").fetch("public_id"))
    failed = settled_review(id, outcome: "failed", after: review_id)
    failed_review_id = failed.fetch("run_public_id")
    failed_review = completed_run(failed_review_id)
    assert_equal ["model_task"], failed_review.tasks.map(&:kind)
    assert_equal "malformed-review-output", @workspace.runs.run(failed_review_id).task(failed_review.tasks.fetch(0).key).output
    assert_equal document.to_h, chat.memory.read(PATH).to_h, "a malformed proposal preserves the saved document"

    chat.memory.delete(PATH, expected_public_id: document.public_id, expected_lock_version: document.lock_version)
    @daemon.stop
    @daemon.start
    @daemon.await_announced(address: "agent")
    @core = Rho::Core.new(home: Rho::Home.resolve(base_url: @base_url, root: @home))
    resumed = cli_json("memory-review", id, "resume", "--json")
    assert_equal failed_review_id, resumed.fetch("run_public_id")
    refute resumed.fetch("pending")
    next_reply = @core.say(id, "!mock reply=forgotten -- I have forgotten the saved memory document.", model: MODEL)
    next_turn = completed_turn(chat, next_reply.fetch("run").fetch("public_id"))
    @daemon.await("the completed reply was not considered after restart") do
      row = chat.store_entries.list.items.find { |entry| entry.namespace == "rho.memory_review" && entry.key == "settings" }
      chat.store_entries.fetch(row.public_id).value.fetch("after_position") >= next_turn.position
    end
    assert_equal failed_review_id, @core.memory_review(id).fetch("run_public_id"), "a missing destination does not start a new review"
    missing = assert_raises(CybrosAgent::Api::NotFound) { chat.memory.read(PATH) }
    assert_equal "memory_not_found", missing.code
    assert_empty chat.memory.grep(pattern: "blue marker", path: "conversation/").fetch("matches")
    assert_equal answer, chat.turns.fetch(source.public_id).active_variant.content,
      "forgetting distilled memory leaves the separately owned conversation source"
    refute cli_json("memory-review", id, "disable", "--json").fetch("enabled")
  end

  # A workspace reader can discover standalone execution. Review must
  # retain the source conversation's narrower access on every content door.
  def test_a_workspace_reader_cannot_read_restricted_sources_or_their_memory_reviews
    other = E2E::ActorProvisioning.world(@base_url).shared_human
    reader = CybrosAgent::Client.new(base_url: @base_url, credential: other.member_token)
    room = @member.workspaces.create(name: "Memory review ACL", access_mode: "account_wide",
      idempotency_key: SecureRandom.uuid)
    @workspace = @member.workspace(room.public_id)
    reader_workspace = reader.workspace(room.public_id)
    assert_equal room.public_id, reader.workspaces.fetch(room.public_id).public_id,
      "workspace access must succeed so concealment is the conversation ACL's result"
    assert_empty reader_workspace.inference_requests.list.items

    opened = @core.open_conversation(model: MODEL, directory: @project, workspace_public_id: room.public_id)
    id = opened.fetch("conversation").fetch("public_id")
    chat = @workspace.conversation(id)
    chat.set_access(default: "none", entries: [{ user_public_id: @steward.public_id, level: "full" }])
    assert_raises(CybrosAgent::Api::NotFound) { reader_workspace.conversation(id).fetch }
    @core.enable_memory_review(id, path: PATH, workspace_public_id: room.public_id)
    private_note = "The private release checklist uses a violet marker."
    answer = JSON.generate("content" => "# Memory\n\n#{private_note}\n", "summary" => "Reviewed the private release checklist.")
    accepted = @core.say(id, "!mock raw_reply=#{CGI.escape(answer)} -- #{private_note}",
      model: MODEL, workspace_public_id: room.public_id)
    source_run_id = accepted.fetch("run").fetch("public_id")
    source = completed_turn(chat, source_run_id)
    reviewed = settled_review(id, outcome: "updated")
    side_id = reviewed.fetch("review_conversation_public_id")
    review_run_id = reviewed.fetch("run_public_id")
    side = @workspace.conversation(side_id)
    assert_predicate side.fetch, :side?
    assert_equal "none", side.fetch.access.default
    assert_includes chat.memory.read(PATH).content, private_note
    assert_equal answer, chat.turns.fetch(source.public_id).active_variant.content

    [id, side_id].each do |conversation_id|
      concealed = reader_workspace.conversation(conversation_id)
      assert_raises(CybrosAgent::Api::NotFound) { concealed.fetch }
      assert_raises(CybrosAgent::Api::NotFound) { concealed.turns.list }
      assert_raises(CybrosAgent::Api::NotFound) { concealed.store_entries.list }
      assert_raises(CybrosAgent::Api::NotFound) { concealed.memory.read(PATH) }
    end
    [source_run_id, review_run_id].each do |run_id|
      run = completed_run(run_id)
      assert_equal ["model_task"], run.tasks.map(&:kind)
      concealed = reader_workspace.runs.run(run_id)
      assert_raises(CybrosAgent::Api::NotFound) { concealed.fetch }
      assert_raises(CybrosAgent::Api::NotFound) { concealed.graph }
      assert_raises(CybrosAgent::Api::NotFound) { concealed.transcript }
      run.tasks.each do |task|
        request = @workspace.runs.run(run_id).tasks_context(task.key).request
        assert_includes JSON.generate(request.entries), private_note
        assert_raises(CybrosAgent::Api::NotFound) { concealed.task(task.key) }
        assert_raises(CybrosAgent::Api::NotFound) { concealed.tasks_context(task.key).request }
      end
    end
    assert_empty reader_workspace.runs.list.items, "neither source nor review escapes through the workspace run list"
    assert_empty @workspace.inference_requests.list.items, "review never copies private content into a standalone InferenceRequest"
    assert_empty reader_workspace.inference_requests.list.items
  end

  def test_a_review_input_blocked_after_submission_settles_without_changing_memory
    opened = @core.open_conversation(model: MODEL, directory: @project)
    id = opened.fetch("conversation").fetch("public_id")
    chat = @workspace.conversation(id)
    @core.enable_memory_review(id, path: PATH, model: "dev/missing-review-model")
    initial = chat.memory.read(PATH)
    accepted = @core.say(id, "!mock reply=source -- Verified the release checklist.", model: MODEL)
    source = completed_turn(chat, accepted.fetch("run").fetch("public_id"))
    reviewed = settled_review(id, outcome: "failed")
    assert_nil reviewed.fetch("run_public_id"), "a blocked input never starts a review run"
    side = @workspace.conversation(reviewed.fetch("review_conversation_public_id"))
    assert_predicate side.fetch, :side?
    assert_empty side.inputs.list.items, "the blocked input cannot resume after review has failed"
    assert_empty side.turns.list.items.reject(&:inherited?)
    assert_equal initial.to_h, chat.memory.read(PATH).to_h
    assert_equal "completed", chat.turns.fetch(source.public_id).status
  end

  def test_the_human_platform_persona_is_the_same_document_as_the_member_persona
    E2E::SessionSignInBudget.consume
    grant = CybrosAgent::Sessions.new(base_url: @base_url).create(email: @steward.email, password: @steward.password)
    E2E::SecretHygiene.register(grant.token)
    @operator = CybrosAgent::PlatformClient.new(base_url: @base_url, credential: grant.token)
    previous = begin
      @operator.persona.read
    rescue CybrosAgent::Api::NotFound
      nil
    end
    content = "Prefer concise answers and state uncertainty clearly."
    saved = @operator.persona.write(content)
    assert_equal content, @operator.persona.read.content
    assert_equal saved.to_h, @member.profile.prompt_documents.read("persona").to_h

    @daemon.stop
    @daemon.start
    @daemon.await("rho never readopted its workspace") { @daemon.status.dig("workspace", "state") == "adopted" }
    @daemon.await_announced(address: "agent")
    @core = Rho::Core.new(home: Rho::Home.resolve(base_url: @base_url, root: @home))
    assert_equal saved.to_h, @operator.persona.read.to_h
    assert_equal saved.to_h, @member.profile.prompt_documents.read("persona").to_h
    opened = @core.open_conversation(model: MODEL, directory: @project)
    id = opened.fetch("conversation").fetch("public_id")
    accepted = @core.say(id, "!mock reply=persona-loaded -- Acknowledge the saved preferences.", model: MODEL)
    run_id = accepted.fetch("run").fetch("public_id")
    run = completed_run(run_id)
    assert_equal ["model_task"], run.tasks.map(&:kind)
    request = @workspace.runs.run(run_id).tasks_context(run.tasks.fetch(0).key).request
    prompt = JSON.generate(request.entries)
    assert_includes prompt, content
    assert_includes prompt, "Prefer at most three agent levels in total"

    replaced = @operator.persona.write("Use numbered steps for procedures.")
    assert_operator replaced.version, :>, saved.version
    assert_equal replaced.to_h, @member.profile.prompt_documents.read("persona").to_h
    @operator.persona.delete
    missing = assert_raises(CybrosAgent::Api::NotFound) { @operator.persona.read }
    assert_equal "prompt_document_not_found", missing.code
    assert_raises(CybrosAgent::Api::NotFound) { @member.profile.prompt_documents.read("persona") }
  ensure
    if @operator
      if previous
        @operator.persona.write(previous.content, role: previous.role)
      else
        begin
          @operator.persona.delete
        rescue CybrosAgent::Api::NotFound
          nil
        end
      end
    end
  end

  private

    def cli_json(*arguments)
      output, status = @daemon.cli(*arguments)
      assert_predicate status, :success?, E2E::SecretHygiene.redact(output)
      JSON.parse(output)
    end

    def completed_turn(chat, run_id)
      completed_run(run_id)
      @daemon.await("the source reply did not complete") do
        chat.turns.list.items.find { |turn| turn.status == "completed" && turn.active_variant&.run_public_id == run_id }
      end
    end

    def settled_review(id, outcome:, after: nil)
      result = @daemon.await("memory review did not finish as #{outcome}") do
        current = @core.memory_review(id, workspace_public_id: @workspace.public_id)
        current if current.fetch("outcome") && !current.fetch("pending") &&
          (!after || current.fetch("run_public_id") != after)
      end
      assert_equal outcome, result.fetch("outcome"), result.inspect
      refute result.fetch("pending")
      result
    rescue RuntimeError
      status = @core.memory_review(id, workspace_public_id: @workspace.public_id)
      warn "review status: #{status.inspect}"
      if (side_id = status["review_conversation_public_id"])
        side = @workspace.conversation(side_id)
        warn "review inputs: #{side.inputs.list.items.map { |row| row.to_h.slice(:public_id, :state, :blocked_reason) }.inspect}"
        warn "review turns: #{side.turns.list.items.map { |row| row.to_h.slice(:public_id, :status, :inherited) }.inspect}"
      end
      raise
    end

    def completed_run(id)
      result = @daemon.await("run #{id} did not settle") do
        row = @workspace.runs.run(id).fetch
        row if row.terminal? || row.needs_attention?
      end
      assert_equal "completed", result.status, result.to_h.inspect
      result
    end
end
