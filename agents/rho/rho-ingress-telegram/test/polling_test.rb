require "support/runtime"
require "support/bridge"

class TelegramPollingTest < Minitest::Test
  include TelegramRuntimeSupport

  def setup
    super
    @core = TelegramBridgeSupport::Core.new
    @member = TelegramBridgeSupport::Member.new
    host = TelegramBridgeSupport::Host.new(home: @home, member_plane: ->(**options) do
      Rho::Extensions::MemberPlane.new(client: @member, workspace_public_id: options.fetch(:workspace_public_id))
    end)
    @bridge = Rho::IngressTelegram::Bridge.new(host: host, core: @core)
    @runtime = runtime
    @state.change do |document|
      document.fetch("routes")["1:0"] = { "chat_id" => "1", "group" => false, "current" => "c-13",
        "conversations" => (1..13).to_h { |id| ["c-#{id}", { "position" => nil, "workspace_public_id" => "original" }] } }
    end
    @core.run_rows = (1..13).map { |id| { "public_id" => "c-#{id}", "sequence" => 1, "status" => "completed", "loop" => "loop-#{id}" } }
  end

  def test_thirteen_idle_conversations_share_attention_reads_without_polling_every_history
    60.times do
      @runtime.tick
      @now += 1
    end

    assert_equal 13, calls(:turns), "quiet histories need only their initial durable read within the first minute"
    assert_equal 13, calls(:scheduled_jobs), "job discovery shares the bounded history cadence"
    assert_equal 13, calls(:inputs), "the current queue is read with history, not on every attention pass"
    assert_equal 12, calls(:asks), "one addressed executor inbox read per pass, not per conversation"
    assert_equal 12, @member.calls.count { |call| call.first == :list }, "one attention page per workspace per pass"
    assert_equal 0, calls(:attach), "existing local followers do not need another remote conversation fetch"
    assert_equal 120, calls(:loops), "main and side snapshots are local and each is read once per second"
    assert_empty @client.calls, "idle historical rooms produce no progress traffic"
  end

  def test_a_later_background_answer_is_delivered_at_reconciliation_and_checked_again_before_send
    @runtime.tick
    @core.define_singleton_method(:turns) do |id, **options|
      rows = super(id, **options)
      id == "c-1" ? rows : { "turns" => [] }
    end
    @core.turn_rows = [{ "public_id" => "late", "position" => 0, "kind" => "direct_reply", "status" => "completed",
      "active_variant" => { "public_id" => "variant-late", "content" => "Background finished" } }]
    @core.run_rows.first["sequence"] += 1
    4.times do
      @now += 1
      @runtime.tick
    end
    assert_empty @client.calls
    @now += 1
    @runtime.tick

    assert_equal 1, @client.calls.count { |method, params| method == "sendMessage" && params[:text] == "Background finished" }
    assert_equal 0, @state.read.fetch("routes").dig("1:0", "conversations", "c-1", "position")
    assert_nil @state.read.fetch("routes").dig("1:0", "conversations", "c-2", "position")
    assert @core.calls.any? { |call| call.first == :turns && call.last[:before_position] == 1 && call.last[:limit] == 1 },
      "the slower discovery cadence never replaces the exact source/variant send check"
  end

  def test_local_progress_observes_a_tool_change_between_remote_reconciliations
    @runtime.instance_variable_set(:@delivery, Rho::IngressTelegram::Delivery.new(client: @client, state: @state,
      clock: -> { @now }, limits: Rho::IngressTelegram::RateLimit.new(clock: -> { @now })))
    current = @core.run_rows.last
    current.merge!("status" => "running", "tasks" => [{ "status" => "running", "kind" => "model_task" }])
    @runtime.tick
    assert_includes @client.calls.last.last.fetch(:text), "Thinking"

    current["tasks"] = [{ "status" => "running", "kind" => "tool_task" }]
    @now += 1
    @runtime.tick
    assert_includes @client.calls.last.last.fetch(:text), "Running a tool"
    assert_equal 2, @client.calls.length
    assert_equal 13, calls(:turns), "local activity does not repeat the remote history read"
    assert_equal 1, calls(:asks)
  end

  def test_a_missing_follower_is_periodically_reattached_in_its_original_workspace
    @runtime.tick
    @core.run_rows.reject! { |row| row.fetch("public_id") == "c-1" }
    @now += 1
    @runtime.tick
    assert_equal 0, calls(:attach)

    @now += 4
    @runtime.tick
    assert_equal [:attach, "c-1", { host_type: "conversation", workspace_public_id: "original" }],
      @core.calls.find { |call| call.first == :attach }
    @core.run_rows << { "public_id" => "c-1", "status" => "running", "loop" => "restored-loop",
      "tasks" => [{ "status" => "running", "kind" => "tool_task" }] }
    @now += 5
    @runtime.tick
    assert_equal 1, calls(:attach), "restoration resumes the local follower instead of attaching every tick"
  end

  private

    def calls(operation) = @core.calls.count { |call| call.first == operation }
end
