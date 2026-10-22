require "test_helper"
require "rho/conversation_titles"
require_relative "support/environment_fixtures"

class ConversationTitlesTest < Minitest::Test
  Document = Data.define(:title, :lock_version)
  Input = Data.define(:public_id, :replayed) do
    def replayed? = replayed
  end
  Result = Data.define(:status, :output_text)
  Accepted = Data.define(:public_id)
  Materialization = Data.define(:turn_public_id, :variant_public_id)
  Variant = Data.define(:public_id, :status, :content)
  Turn = Data.define(:status, :active_variant)
  Queued = Data.define(:public_id, :state)
  Page = Data.define(:items)
  Forked = Data.define(:conversation)
  Workspace = Data.define(:inference_requests, :side) do
    def conversation(public_id)
      raise "unexpected conversation #{public_id}" unless public_id == side.public_id

      side
    end
  end

  class Conversation
    attr_reader :updates, :public_id, :forks
    attr_accessor :document, :before_update

    def initialize(side)
      @public_id = "conversation-1"
      @document = Document.new(title: nil, lock_version: 0)
      @updates, @forks, @side = [], [], side
    end

    def fetch = document

    def fork(**fields)
      @forks << fields
      Forked.new(conversation: @side)
    end

    def update(title:, lock_version:)
      before_update&.call
      raise CybrosAgent::Api::Conflict.new("Changed", code: "stale_object") if lock_version != document.lock_version

      @updates << title
      @document = document.with(title: title, lock_version: lock_version + 1)
    end
  end

  class Lane
    attr_reader :creates
    attr_accessor :result, :on_create, :materialized, :blocked

    def initialize
      @creates = []
      @materialized, @blocked = true, false
      @result = Result.new(status: "completed", output_text: "项目计划")
    end

    def create(**fields)
      @creates << fields
      on_create&.call
      Accepted.new(public_id: "title-input")
    end

    def materialization(public_id)
      raise "unexpected input #{public_id}" unless public_id == "title-input"

      Materialization.new(turn_public_id: "title-turn", variant_public_id: "title-variant") if materialized
    end

    def list = Page.new(items: [Queued.new(public_id: "title-input", state: blocked ? "blocked" : "pending")])
  end

  class Side
    attr_reader :public_id, :inputs, :deletions
    attr_accessor :variant_public_id, :delete_error

    def initialize(inputs)
      @public_id, @inputs, @deletions = "title-side", inputs, 0
      @variant_public_id = "title-variant"
    end

    def turns = self

    def fetch(public_id)
      raise "unexpected turn #{public_id}" unless public_id == "title-turn"

      status = inputs.result&.status || "running"
      Turn.new(status: status,
        active_variant: Variant.new(public_id: variant_public_id, status: status, content: inputs.result&.output_text))
    end

    def delete
      @deletions += 1
      raise delete_error if delete_error
    end
  end

  def setup
    @store = RhoTest::EnvironmentFixtures::FakeStore.new
    @lane = Lane.new
    @side = Side.new(@lane)
    @conversation = Conversation.new(@side)
    @workspace_inference = Lane.new
    @workspace = Workspace.new(inference_requests: @workspace_inference, side: @side)
    @tasks, @warnings = [], []
    @now = Time.now
    @config = Rho::Config::Current.new(Rho::Config.from_hash({}))
    @logger = Object.new
    @logger.define_singleton_method(:warn) { |*args, **fields| @warnings << [args, fields] }
    @logger.instance_variable_set(:@warnings, @warnings)
    @titles = Rho::ConversationTitles.new(config: @config, log: @logger, clock: -> { @now }, sleeper: ->(seconds) { @now += seconds })
    policy.establish(title_pending: true)
  end

  def test_first_accepted_input_runs_in_background_on_its_model_and_writes_once
    accept
    assert_empty @lane.creates, "submission schedules the model work without waiting for it"
    refute policy.read.title_pending
    assert_equal "input-1", policy.read.title_input_public_id
    @config.apply(@config.with({ "conversation_title_model" => "dev/changed" }))
    @tasks.shift.call

    assert_equal "dev/current", @lane.creates.first.fetch(:model)
    assert_equal "direct_reply", @lane.creates.first.fetch(:kind)
    assert_equal "raw", @lane.creates.first.fetch(:context_mode)
    assert_equal "帮我规划项目", @lane.creates.first.fetch(:entries).last.fetch("parts").first.fetch("text")
    assert_equal Rho::ConversationTitles::INSTRUCTIONS, @lane.creates.first.fetch(:instructions)
    assert_equal [], @lane.creates.first.fetch(:tool_names)
    refute @lane.creates.first.fetch(:visible_in_context)
    assert_equal "项目计划", @conversation.document.title
    assert_empty @lane.creates.first.fetch(:fallback_models)
    assert_equal [{ side: true, title: "Conversation title", idempotency_key: "rho.conversation_title:input-1" }], @conversation.forks
    assert_equal 1, @side.deletions
    accept(input: "input-2", text: "later request")
    assert_empty @tasks
    assert_equal 1, @lane.creates.length
  end

  def test_an_explicit_title_model_does_not_require_tool_call_support
    @config.apply(@config.with({ "conversation_title_model" => "dev/text-only" }))
    accept
    @tasks.shift.call
    assert_equal "dev/text-only", @lane.creates.first.fetch(:model)
  end

  def test_title_generation_never_copies_conversation_text_into_a_workspace_inference_request
    accept(text: "The private release checklist uses a violet marker.")
    @tasks.shift.call

    assert_empty @workspace_inference.creates,
      "title execution must retain its source conversation's access instead of creating a workspace-wide copy"
    assert @conversation.forks.first.fetch(:side), "the source owns the title request's inherited access"
    assert_equal "项目计划", @conversation.document.title
    assert_equal 1, @side.deletions, "the temporary title side does not remain in the side collection"
  end

  def test_none_consumes_the_first_opportunity_without_a_model_call
    @config.apply(@config.with({ "conversation_title_model" => nil }))
    accept
    @config.apply(@config.with({ "conversation_title_model" => "follow_current" }))
    accept(input: "later")
    assert_empty @tasks
    assert_empty @lane.creates
    refute policy.read.title_pending
  end

  def test_replayed_input_does_not_schedule_another_attempt
    accept(replayed: true)
    assert_empty @tasks
    assert policy.read.title_pending
  end

  def test_a_stale_second_consumer_never_sends_another_title_request
    stale = policy
    assert stale.read.title_pending
    accept
    @titles.accept(policy: stale, conversation: @conversation, input: Input.new(public_id: "input-2", replayed: false),
      text: "second", model: "dev/current", workspace: @workspace,
      spawn: ->(&task) { @tasks << task })
    assert_equal 1, @tasks.length
    @tasks.shift.call
    assert_equal 1, @lane.creates.length
    assert_equal "rho.conversation_title:input-1", @lane.creates.first.fetch(:idempotency_key)
  end

  def test_explicit_title_or_blocked_input_does_not_generate_a_title
    @conversation.document = @conversation.document.with(title: "Chosen by a person")
    accept
    assert_empty @tasks
    refute policy.read.title_pending

    @store = RhoTest::EnvironmentFixtures::FakeStore.new
    policy.establish(title_pending: true)
    @conversation.document = @conversation.document.with(title: nil)
    accept(blocked: true)
    assert_empty @tasks
    refute policy.read.title_pending
  end

  def test_manual_rename_during_inference_wins
    accept
    @lane.on_create = -> { @conversation.document = Document.new(title: "My title", lock_version: 1) }
    @tasks.shift.call
    assert_equal "My title", @conversation.document.title
    assert_empty @conversation.updates
    assert_equal 1, @side.deletions
  end

  def test_manual_rename_between_the_final_read_and_patch_wins_without_retry
    accept
    @conversation.before_update = -> { @conversation.document = Document.new(title: "Last instant", lock_version: 1) }
    @tasks.shift.call
    assert_equal "Last instant", @conversation.document.title
    assert_empty @conversation.updates
    assert_equal 1, @lane.creates.length
  end

  def test_a_normal_reply_version_change_retries_once_without_another_inference
    accept
    changes = 0
    @conversation.before_update = lambda do
      if changes.zero?
        @conversation.document = @conversation.document.with(lock_version: 1)
        changes += 1
      end
    end
    @tasks.shift.call
    assert_equal "项目计划", @conversation.document.title
    assert_equal 1, @lane.creates.length
  end

  def test_repeated_version_changes_stop_after_two_writes
    accept
    attempts = 0
    @conversation.before_update = lambda do
      attempts += 1
      @conversation.document = @conversation.document.with(lock_version: @conversation.document.lock_version + 1)
    end
    @tasks.shift.call
    assert_nil @conversation.document.title
    assert_equal 2, attempts
    assert_equal 1, @lane.creates.length
  end

  def test_failed_generation_is_nonfatal_and_a_later_message_does_not_retry
    accept
    @lane.on_create = -> { raise CybrosAgent::TransportError, "synthetic error" }
    @tasks.shift.call
    accept(input: "later")
    assert_empty @tasks
    assert_nil @conversation.document.title
    assert_equal 1, @lane.creates.length
    assert_equal 1, @warnings.length
    assert_equal 1, @side.deletions
  end

  def test_output_is_a_bounded_plain_single_line_and_empty_output_is_ignored
    @lane.result = Result.new(status: "completed", output_text: "  \"#{"文" * 300}\"\nextra explanation ")
    accept
    @tasks.shift.call
    assert_equal "文" * 255, @conversation.document.title

    @store = RhoTest::EnvironmentFixtures::FakeStore.new
    policy.establish(title_pending: true)
    @conversation.document = Document.new(title: nil, lock_version: 0)
    @lane.result = Result.new(status: "completed", output_text: " \n ")
    accept(input: "empty-result")
    @tasks.shift.call
    assert_nil @conversation.document.title
  end

  def test_a_model_that_does_not_finish_is_cancelled_at_the_bound
    @lane.result = nil
    accept
    @tasks.shift.call
    assert_equal 1, @side.deletions, "discarding the side stops its unfinished title execution"
    assert_nil @conversation.document.title
  end

  def test_an_input_that_never_materializes_is_discarded_at_the_same_bound
    @lane.materialized = false
    accept
    @tasks.shift.call
    assert_equal 1, @side.deletions, "discarding the side also removes its pending input"
    assert_nil @conversation.document.title
  end

  def test_a_blocked_input_is_discarded_without_waiting_or_retrying
    @lane.materialized = false
    @lane.blocked = true
    started = @now
    accept
    @tasks.shift.call
    assert_equal started, @now
    assert_equal 1, @side.deletions
    assert_nil @conversation.document.title
  end

  def test_failed_or_stopped_title_work_is_discarded_without_publishing
    %w[failed canceled timed_out].each do |status|
      @store = RhoTest::EnvironmentFixtures::FakeStore.new
      policy.establish(title_pending: true)
      @lane.result = Result.new(status: status, output_text: "Not a title")
      accept
      @tasks.shift.call
      assert_nil @conversation.document.title
    end
    assert_equal 3, @side.deletions
  end

  def test_a_replaced_variant_does_not_become_the_generated_title
    @side.variant_public_id = "different-variant"
    accept
    @tasks.shift.call
    assert_nil @conversation.document.title
    assert_equal 1, @side.deletions
  end

  def test_stopping_the_background_task_discards_its_side
    @lane.on_create = -> { raise Async::Stop }
    accept
    assert_raises(Async::Stop) { @tasks.shift.call }
    assert_equal 1, @side.deletions
    assert_nil @conversation.document.title
  end

  def test_server_shutdown_discards_a_pending_title_without_publishing
    waiting = Thread::Queue.new
    @lane.result = nil
    @titles = Rho::ConversationTitles.new(config: @config, log: @logger,
      sleeper: ->(_seconds) { waiting << true; sleep })
    accept
    control = Rho::ControlServer.new(bind: "127.0.0.1", port: 0, routes: {})
    control.spawn(&@tasks.shift)
    control.run
    assert waiting.pop(timeout: 5), "the accepted title input is still running"

    control.stop

    assert_equal 1, @side.deletions
    assert_nil @conversation.document.title
  ensure
    control&.stop
  end

  def test_a_side_already_removed_by_its_parent_needs_no_further_cleanup
    @side.delete_error = CybrosAgent::Api::NotFound.new("Gone", code: "not_found")
    accept
    @tasks.shift.call
    assert_empty @warnings
    assert_equal "项目计划", @conversation.document.title
  end

  private

    def policy
      Rho::HostPolicy.new(store: -> { @store }, owner_public_id: "owner", host_public_id: @conversation.public_id)
    end

    def accept(input: "input-1", text: "帮我规划项目", replayed: false, blocked: false)
      @titles.accept(policy: policy, conversation: @conversation, input: Input.new(public_id: input, replayed: replayed),
        text: text, model: "dev/current", workspace: @workspace,
        spawn: ->(&task) { @tasks << task }, blocked: blocked)
    end
end
