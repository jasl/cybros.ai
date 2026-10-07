require "minitest/autorun"
require "tmpdir"
require "fileutils"

module HouseholdTest
  Extension = Module.new
  path = File.expand_path("../extension.rb", __dir__)
  Extension.module_eval(File.read(path), path)

  Row = Data.define(:public_id, :namespace, :key, :value, :lock_version)
  Page = Data.define(:items)
  Created = Data.define(:schedule)
  Schedule = Data.define(:public_id, :last_execution)
  Execution = Data.define(:child_conversation_public_id)
  Parent = Data.define(:public_id)
  Session = Data.define(:store, :jobs, :conversation) do
    def creation_fields
      { model: "fixture/model", approval_mode: "default", to: "fixture-agent",
        tool_names: ["household_cleaning_version"], source_run_public_id: "fixture-run", source_task_key: "fixture-task",
        idempotency_key: "task-original-key" }
    end
  end
  Conversation = Data.define(:store_entries, :schedules)
  ChildConversation = Data.define(:parent) do
    def fetch = self
    def schedules = nil
  end
  Workspace = Data.define(:conversation_row) do
    def conversation(_) = conversation_row
  end
  ScopedWorkspace = Data.define(:conversations) do
    def conversation(id) = conversations.fetch(id)
  end
  Client = Data.define(:workspace_row) do
    def workspace(_) = workspace_row
  end

  class Store
    attr_reader :rows
    def initialize = @rows = {}
    def list(**) = Page.new(items: rows.values)
    def fetch(id) = rows.fetch(id)
    def create(namespace:, key:, value:, **)
      raise "duplicate room" if rows.values.any? { |row| row.namespace == namespace && row.key == key }

      id = SecureRandom.uuid_v7
      rows[id] = Row.new(public_id: id, namespace: namespace, key: key, value: value, lock_version: 0)
    end
    def update(id, value:, lock_version:)
      prior = rows.fetch(id)
      raise "stale write" unless prior.lock_version == lock_version

      rows[id] = prior.with(value: value, lock_version: lock_version + 1)
    end
  end

  class Jobs
    attr_reader :rows, :cancelled
    attr_accessor :lose_response, :after_create
    def initialize
      @rows, @cancelled = {}, []
    end
    def create(**fields)
      key = fields.fetch(:idempotency_key)
      existing = rows[key]
      raise "changed schedule retry" if existing && existing.fetch(:fields) != fields

      record = rows[key] ||= { fields: fields, schedule: Schedule.new(public_id: SecureRandom.uuid_v7, last_execution: nil) }
      callback, @after_create = @after_create, nil
      callback&.call
      if lose_response
        @lose_response = false
        raise IOError, "accepted schedule response lost"
      end
      Created.new(schedule: record.fetch(:schedule))
    end
    def cancel(id)
      cancelled << id unless cancelled.include?(id)
    end
    def fetch(id) = rows.values.find { |row| row.fetch(:schedule).public_id == id }.fetch(:schedule)
  end

  class Notices
    attr_reader :delivered
    attr_accessor :lose_response
    def initialize = @delivered = {}
    def deliver(idempotency_key:, recipient:, message:)
      receipt = delivered[idempotency_key] ||= { "receipt" => SecureRandom.uuid_v7, "recipient" => recipient, "message" => message,
        "adapter" => "test-idempotent-sink", "simulated" => true }
      if lose_response
        @lose_response = false
        raise IOError, "accepted notice response lost"
      end
      receipt
    end
  end
end

class HouseholdLedgerTest < Minitest::Test
  include HouseholdTest

  def setup
    @now = Time.iso8601("2026-10-07T02:00:00Z")
    @store, @jobs, @notices = Store.new, Jobs.new, Notices.new
    @session = Session.new(store: @store, jobs: @jobs, conversation: "fixture-home-conversation")
    @raw = JSON.parse(File.read(File.expand_path("../configuration.json", __dir__))).merge("enabled" => true)
  end

  def ledger(raw: @raw, session: @session)
    Extension::Ledger.new(configuration: Extension::Configuration.parse(raw), session: session,
      tool_name: "household_cleaning_version", notifier: @notices, clock: -> { @now })
  end

  def call(action, **fields)
    ledger.call({ "action" => action, "room" => "hall" }.merge(fields.transform_keys(&:to_s)))
  end

  def observe(id: "observation-1", at: @now, finding: "untidy")
    call("observe", event_id: id, source: "fixture-observer", observed_at: at.iso8601, finding: finding)
  end

  def assign
    observe
    call("triage", reason: "The reported spill needs cleaning")
  end

  def current_work = call("status").fetch("cleaning")

  def evidence(action, **fields)
    call(action, work_id: current_work.fetch("id"), worker: "fixture-worker", source: "fixture-worker-report",
      note: action == "acknowledge" ? "Accepted the assignment" : "Spill removed; checked the floor", **fields)
  end

  def test_observations_require_triage_and_repeated_events_keep_one_outstanding_work
    observe
    assert_nil current_work
    assert_empty @notices.delivered
    initial = call("triage", reason: "The spill needs cleaning").fetch("cleaning")
    @now += 30
    observe(id: "observation-2")
    retried = call("triage", reason: "Still looks untidy").fetch("cleaning")
    assert_equal initial.fetch("id"), retried.fetch("id")
    assert_equal 1, @store.rows.length
    assert_equal 1, @jobs.rows.length
    assert_equal 1, @notices.delivered.length
    assert_equal "assigned", retried.fetch("status")
  end

  def test_acknowledgement_and_completion_have_distinct_evidence_and_stop_reminders
    assign
    assert_raises(Extension::Error) { evidence("complete") }
    acknowledgement = evidence("acknowledge").fetch("cleaning")
    assert_equal "acknowledged", acknowledgement.fetch("status")
    assert_nil acknowledgement["completion"]
    completed = evidence("complete").fetch("cleaning")
    assert_equal "completed", completed.fetch("status")
    refute_equal completed.fetch("acknowledgement").fetch("note"), completed.fetch("completion").fetch("note")
    assert_equal [completed.fetch("schedule_id")], @jobs.cancelled
    @now += 7200
    call("remind", work_id: completed.fetch("id"))
    assert_equal 1, @notices.delivered.length
  end

  def test_old_observation_cannot_reopen_completed_work
    assigned = assign.fetch("cleaning")
    evidence("acknowledge")
    evidence("complete")
    assert_equal assigned.fetch("id"), call("triage", reason: "Retry the old request").fetch("cleaning").fetch("id")
    assert_equal 1, @notices.delivered.length
    @now += 30
    observe(id: "another-spill")
    refute_equal assigned.fetch("id"), call("triage", reason: "New spill reported").fetch("cleaning").fetch("id")
  end

  def test_lost_notification_response_retries_same_key_without_duplicate_notice
    observe
    @notices.lose_response = true
    assert_raises(IOError) { call("triage", reason: "Spill") }
    assert_equal 1, @notices.delivered.length
    # A fresh object models a process restart: only Nexus and the receiving
    # adapter retain state; there is no local delivery log to reconstruct.
    report = ledger.call("action" => "triage", "room" => "hall", "reason" => "Retry")
    assert_equal 1, report.fetch("cleaning").fetch("notice_count")
    assert_equal 1, @notices.delivered.length
  end

  def test_lost_schedule_response_retries_frozen_request_without_second_schedule
    observe
    @jobs.lose_response = true
    assert_raises(IOError) { call("triage", reason: "Spill") }
    assert_empty @notices.delivered
    ledger.call("action" => "triage", "room" => "hall", "reason" => "Retry")
    assert_equal 1, @jobs.rows.length
    assert_equal 1, @notices.delivered.length
    fields = @jobs.rows.values.first.fetch(:fields)
    assert_equal "interval", fields.fetch(:rule).fetch("kind")
    assert_includes fields.fetch(:prompt), "household_cleaning_version"
  end

  def test_reminder_uses_durable_schedule_and_survives_new_extension_instance
    report = assign
    schedule = @jobs.rows.values.first
    assert_equal report.fetch("cleaning").fetch("schedule_id"), schedule.fetch(:schedule).public_id
    @now += 3600
    fresh = ledger
    args = { "action" => "remind", "room" => "hall", "work_id" => report.fetch("cleaning").fetch("id") }
    assert_equal 2, fresh.call(args).fetch("cleaning").fetch("notice_count")
    assert_equal 2, ledger.call(args).fetch("cleaning").fetch("notice_count")
    assert_equal 2, @notices.delivered.length
    assert_equal 1, @jobs.rows.length
  end

  def test_completion_during_schedule_creation_cancels_the_created_schedule_and_keeps_evidence
    observe
    @jobs.after_create = lambda do
      evidence("acknowledge")
      evidence("complete")
    end
    result = call("triage", reason: "Spill").fetch("cleaning")
    assert_equal "completed", result.fetch("status")
    assert_equal "Spill removed; checked the floor", result.fetch("completion").fetch("note")
    assert_equal [result.fetch("schedule_id")], @jobs.cancelled
    assert_empty @notices.delivered
  end

  def test_stale_check_in_is_labelled_with_source_and_time
    call("check_in", event_id: "check-in-1", source: "fixture-check-in", observed_at: (@now - 3600).iso8601,
      worker: "fixture-worker", reported_room: "entry")
    location = call("status").fetch("worker_location")
    assert_equal "stale_report", location.fetch("freshness")
    assert_equal "fixture-check-in", location.fetch("source")
    assert_equal (@now - 3600).iso8601, location.fetch("observed_at")
    refute location.key?("current_room")
  end

  def test_stale_observation_never_authorizes_a_new_assignment
    observe(at: @now - 3600)
    assert_raises(Extension::Error) { call("triage", reason: "Old image") }
    assert_empty @jobs.rows
    assert_empty @notices.delivered
  end

  def test_disabled_rule_and_outside_working_period_do_not_dispatch
    observe
    disabled = ledger(raw: @raw.merge("enabled" => false))
    assert disabled.call("action" => "triage", "room" => "hall", "reason" => "Spill").fetch("actions_suppressed")
    @now = Time.iso8601("2026-10-07T15:00:00Z")
    assert call("triage", reason: "Late evening").fetch("actions_suppressed")
    assert_empty @notices.delivered
    assert_empty @jobs.rows
  end

  def test_disabling_an_existing_rule_suppresses_due_reminders
    assigned = assign.fetch("cleaning")
    @now += 3600
    disabled = ledger(raw: @raw.merge("enabled" => false))
    result = disabled.call("action" => "remind", "room" => "hall", "work_id" => assigned.fetch("id"))
    assert result.fetch("actions_suppressed")
    assert_equal 1, @notices.delivered.length
  end

  def test_private_room_unconfigured_source_and_wrong_worker_are_refused
    assert_raises(Extension::Error) { ledger.call("action" => "status", "room" => "bedroom") }
    assert_raises(Extension::Error) do
      call("observe", event_id: "x", source: "unagreed-camera", observed_at: @now.iso8601, finding: "untidy")
    end
    assign
    assert_raises(Extension::Error) { evidence("acknowledge", worker: "somebody-else") }
  end

  def test_status_omits_private_store_and_schedule_authoring_payload
    assign
    report = JSON.generate(call("status"))
    refute_includes report, "schedule_request"
    refute_includes report, "source_run_public_id"
    refute_includes report, "lock_version"
    refute_includes report, "pending_notice"
  end

  def test_copied_conversation_cannot_send_notices_for_original_work
    assign
    copied = @session.with(conversation: "fork")
    assert_raises(Extension::Error) { ledger(session: copied).call("action" => "status", "room" => "hall") }
    assert_equal 1, @notices.delivered.length
  end

  def test_only_the_current_scheduled_child_can_resolve_the_source_household_work
    work = assign.fetch("cleaning")
    scheduled = @jobs.rows.values.first
    scheduled[:schedule] = scheduled.fetch(:schedule).with(last_execution: Execution.new(child_conversation_public_id: "scheduled-child"))
    conversations = {
      @session.conversation => Conversation.new(store_entries: @store, schedules: @jobs),
      "scheduled-child" => ChildConversation.new(parent: Parent.new(public_id: @session.conversation)),
      "older-child" => ChildConversation.new(parent: Parent.new(public_id: @session.conversation)),
      "unrelated-conversation" => ChildConversation.new(parent: nil),
    }
    client = Client.new(workspace_row: ScopedWorkspace.new(conversations: conversations))
    plane = ->(**) { Rho::Extensions::MemberPlane.new(client: client, workspace_public_id: "fixture-workspace") }
    resolve = lambda do |current, id|
      current = Rho::Runner::ExecutionContext.new(conversation_public_id: current, workspace_public_id: "fixture-workspace")
      Rho::Runner::ExecutionContext.with(current) do
        Extension::Session.new(member_plane: plane, source_conversation: @session.conversation, room: "hall", work_id: id)
      end
    end
    restored = resolve.call("scheduled-child", work.fetch("id"))
    assert_same @store, restored.store
    assert_same @jobs, restored.jobs
    assert_equal @session.conversation, restored.conversation
    assert_raises(Extension::Error) { resolve.call("scheduled-child", "other-work") }
    assert_raises(Extension::Error) { resolve.call("older-child", work.fetch("id")) }
    assert_raises(Extension::Error) { resolve.call("unrelated-conversation", work.fetch("id")) }
    assert_equal 1, @notices.delivered.length
  end

  def test_fixture_adapter_explicitly_reports_simulation
    receipt = Extension::FixtureNotifier.new.deliver(idempotency_key: "one", recipient: "worker", message: "Spill")
    assert receipt.fetch("simulated")
    assert_equal "fixture", receipt.fetch("adapter")
    assert_equal receipt, Extension::FixtureNotifier.new.deliver(idempotency_key: "one", recipient: "worker", message: "Spill")
  end

  def test_actual_package_loader_restores_selection_and_completion_uses_normal_result_capture
    assign
    evidence("acknowledge")
    Dir.mktmpdir("household-package-") do |root|
      home = Rho::Home.resolve(base_url: "https://nexus.example", root: File.join(root, "home"))
      home.prepare
      packages = Rho::Packages.new(home: home)
      installed = packages.install(path: File.expand_path("..", __dir__))
      packages.activate(name: "household-ledger", version: installed.fetch(:version), configuration: @raw) do |_sources, persist|
        persist.call
        {}
      end
      sources = Rho::Packages.new(home: home).sources
      assert_equal @raw, sources.first.configuration
      client = Client.new(workspace_row: Workspace.new(conversation_row: Conversation.new(store_entries: @store, schedules: @jobs)))
      plane = ->(**) { Rho::Extensions::MemberPlane.new(client: client, workspace_public_id: "fixture-workspace") }
      config = Rho::Config.load(home.settings_path, home: home)
      host = Rho::Extensions::Host.new(home: home, log: nil, clock: -> { Time.now }, config: config, processes: nil, member_plane: plane)
      loaded = Rho::Extensions.load(host: host, extensions: [], paths: sources.map(&:path), managed: sources)
      assert loaded.ok?, loaded.failures.map(&:message).join("\n")
      assert_equal ["household_cleaning_#{installed.fetch(:version)[0, 12]}"], loaded.registry.serving(:agent).names
      tool = loaded.registrations.first.tools.first.klass
      env = Rho::Runner::ToolEnv.new(root: root, artifacts_dir: File.join(root, "artifacts"))
      context = Rho::Runner::ExecutionContext.new(conversation_public_id: @session.conversation, workspace_public_id: "fixture-workspace",
        run_public_id: "fixture-run", task_key: "fixture-completion")
      result = Rho::Runner::ExecutionContext.with(context) do
        tool.new(env: env).call("action" => "complete", "room" => "hall", "work_id" => current_work.fetch("id"),
          "worker" => "fixture-worker", "source" => "fixture-worker-report", "note" => "Floor inspected and clear")
      end
      refute result.is_error, result.content
      assert result.files_required
      assert_equal 1, result.files.length
      evidence = JSON.parse(File.read(result.files.first)).fetch("cleaning")
      assert_equal "completed", evidence.fetch("status")
      assert_equal "Floor inspected and clear", evidence.fetch("completion").fetch("note")
    end
  end
end
