require "rho"
require "rho/runner"
require "json"
require "time"
require "digest"
require "securerandom"

# Loaded inside the package's own module by rho's existing extension loader.
class Error < Rho::Error; end

Configuration = Data.define(:enabled, :rooms, :sources, :days, :starts, :ends, :offset, :freshness, :reminder) do
  def self.parse(raw)
    raw = raw.to_h
    rooms = raw.fetch("public_rooms").to_h.transform_keys(&:to_s).transform_values(&:to_s)
    sources = raw.fetch("sources").map(&:to_s)
    days = raw.fetch("working_days").map { |day| Integer(day) }
    offset = raw.fetch("utc_offset").to_s
    Time.now.getlocal(offset)
    minute = lambda do |value|
      raise Error, "working time must be HH:MM" unless value.match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/)

      hour, minutes = value.split(":").map(&:to_i)
      hour * 60 + minutes
    end
    starts, ends = %w[starts_at ends_at].map { |key| minute.call(raw.fetch(key).to_s) }
    freshness = Integer(raw.fetch("fresh_for_seconds", 900))
    reminder = Integer(raw.fetch("remind_every_seconds", 3600))
    enabled = raw.fetch("enabled", false)
    unless [true, false].include?(enabled) && rooms.length.between?(1, 16) && rooms.all? { |room, worker| room.length.between?(1, 100) && worker.length.between?(1, 100) } &&
        !sources.empty? && !days.empty? && days.all? { |day| (0..6).cover?(day) } && starts < ends &&
        freshness.between?(60, 86_400) && reminder.between?(60, 604_800)
      raise Error, "configure public rooms with recipients, sources, working days/times and bounded freshness/reminder intervals"
    end
    new(enabled: enabled, rooms: rooms, sources: sources, days: days, starts: starts, ends: ends,
      offset: offset, freshness: freshness, reminder: reminder)
  rescue KeyError, TypeError, NoMethodError, ArgumentError
    raise Error, "household configuration is incomplete or malformed", cause: nil
  end

  def actions_allowed?(now)
    local = now.getlocal(offset)
    minute = local.hour * 60 + local.min
    enabled && days.include?(local.wday) && minute >= starts && minute < ends
  end
end

# A deliberately effect-free adapter. A real replacement must reconcile this
# key at the receiving service before it claims delivery after a lost response.
class FixtureNotifier
  def deliver(idempotency_key:, recipient:, message:)
    { "receipt" => "fixture-#{Digest::SHA256.hexdigest(idempotency_key)[0, 20]}",
      "adapter" => "fixture", "simulated" => true, "recipient" => recipient, "message" => message }
  end
end

class Session < Rho::Extensions::Schedules::Session
  attr_reader :store, :conversation

  def initialize(member_plane:, source_conversation: nil, room: nil, work_id: nil)
    super(member_plane: member_plane)
    @conversation = source_conversation || context.conversation_public_id
    source = workspace.conversation(@conversation)
    @store, @jobs = source.store_entries, source.schedules
    if @conversation != context.conversation_public_id
      current = workspace.conversation(context.conversation_public_id).fetch
      raise Error, "a reminder must execute in its source conversation's scheduled child" unless current.parent&.public_id == @conversation

      entry = @store.list(limit: 100).items.find { |item| item.namespace == Ledger::NAMESPACE && item.key == room }
      work = entry && @store.fetch(entry.public_id).value["work"]
      unless work && work.fetch("id") == work_id && work["schedule_id"] &&
          @jobs.fetch(work.fetch("schedule_id")).last_execution&.child_conversation_public_id == context.conversation_public_id
        raise Error, "the reminder does not belong to this scheduled execution"
      end
    end
  end
end

class Ledger
  NAMESPACE = "household.cleaning".freeze

  def initialize(configuration:, session:, tool_name:, notifier: FixtureNotifier.new, clock: -> { Time.now })
    @configuration, @session, @tool_name, @notifier, @clock = configuration, session, tool_name, notifier, clock
    @store, @jobs = session.store, session.jobs
  end

  def call(args)
    room = args.fetch("room")
    raise Error, "this room is not in the configured public rooms" unless @configuration.rooms.key?(room)

    row = find(room)
    case args.fetch("action")
    when "status" then nil
    when "observe", "check_in"
      row = record_observation(row, room, args)
    when "triage"
      return projection(row, room).merge("actions_suppressed" => true) unless @configuration.actions_allowed?(@clock.call)

      row = triage(row, room, args)
    when "remind"
      return projection(row, room).merge("actions_suppressed" => true) unless @configuration.actions_allowed?(@clock.call)

      row = remind(row, args)
    when "acknowledge" then row = acknowledge(row, args)
    when "complete" then row = complete(row, args)
    when "cancel_reminders"
      work = work(row, args)
      @jobs.cancel(work.fetch("schedule_id")) if work["schedule_id"]
      row = save(row, "work" => work.merge("reminders_cancelled" => true))
    else raise Error, "unknown household action"
    end
    projection(row, room)
  end

  private

    def find(room)
      entry = @store.list(limit: 100).items.find { |item| item.namespace == NAMESPACE && item.key == room }
      row = entry && @store.fetch(entry.public_id)
      if row && row.value.fetch("conversation") != @session.conversation
        raise Error, "copied household state cannot control the source conversation's work"
      end
      row
    end

    def save(row, changes)
      @store.update(row.public_id, value: row.value.merge(changes), lock_version: row.lock_version)
    end

    def record_observation(row, room, args)
      observed = stamp(args)
      field = args.fetch("action") == "check_in" ? "location" : "observation"
      if field == "location"
        raise Error, "check-in must name the configured worker" unless args.fetch("worker") == @configuration.rooms.fetch(room)

        observed = observed.merge("worker" => args.fetch("worker"), "reported_room" => args.fetch("reported_room"))
      else
        observed = observed.merge("finding" => args.fetch("finding"))
      end
      if row
        previous = row.value[field]
        return row if previous && Time.iso8601(previous.fetch("observed_at")) >= Time.iso8601(observed.fetch("observed_at"))

        save(row, field => observed)
      else
        @store.create(namespace: NAMESPACE, key: room, value: { "conversation" => @session.conversation, field => observed },
          idempotency_key: "household:#{@session.conversation}:#{room}:#{observed.fetch("event_id")}").store_entry
      end
    end

    def stamp(args)
      source = args.fetch("source")
      raise Error, "the observation source is not configured" unless @configuration.sources.include?(source)

      observed_at = Time.iso8601(args.fetch("observed_at"))
      raise Error, "an observation cannot be dated in the future" if observed_at > @clock.call + 60

      { "event_id" => args.fetch("event_id"), "source" => source, "observed_at" => observed_at.iso8601 }
    rescue ArgumentError
      raise Error, "observation time must be an ISO8601 timestamp", cause: nil
    end

    def triage(row, room, args)
      raise Error, "record an observation before triage" unless row

      existing = row.value["work"]
      if existing && existing.fetch("status") != "completed"
        return deliver_pending(ensure_schedule(row))
      end
      observation = row.value.fetch("observation") { raise Error, "record an observation before triage" }
      unless observation.fetch("finding") == "untidy" && fresh?(observation)
        raise Error, "triage needs a fresh untidy observation"
      end
      if existing && existing.dig("triage", "event_id") == observation.fetch("event_id")
        return row
      end

      id = SecureRandom.uuid_v7
      now = @clock.call
      fields = @session.creation_fields.transform_keys(&:to_s).merge(
        "idempotency_key" => "household:#{id}:reminders", "name" => "Cleaning reminder #{id}",
        "prompt" => "Call #{@tool_name} with #{JSON.generate("action" => "remind", "room" => room, "work_id" => id, "source_conversation" => @session.conversation)}. " \
          "The tool checks current enabled rules, working periods and outstanding work. Do not send any independent notice or recreate completed work.",
        "rule" => { "kind" => "interval", "every_seconds" => @configuration.reminder, "starts_at" => (now + @configuration.reminder).iso8601 }
      )
      work = { "id" => id, "status" => "assigned", "assignee" => @configuration.rooms.fetch(room),
        "assigned_at" => now.iso8601, "triage" => observation.merge("reason" => args.fetch("reason")),
        "schedule_request" => fields, "next_reminder_at" => (now + @configuration.reminder).iso8601,
        "pending_notice" => { "key" => "#{id}:assigned", "message" => "Cleaning requested for #{room}: #{args.fetch("reason")}" }, "notice_count" => 0 }
      row = save(row, "work" => work)
      deliver_pending(ensure_schedule(row))
    end

    def ensure_schedule(row)
      work = row.value.fetch("work")
      return row if work["schedule_id"]

      created = @jobs.create(**work.fetch("schedule_request").transform_keys(&:to_sym))
      fresh = @store.fetch(row.public_id)
      current = fresh.value.fetch("work")
      if current.fetch("id") != work.fetch("id") || current.fetch("status") == "completed"
        @jobs.cancel(created.schedule.public_id)
        raise Error, "the cleaning work was replaced while its reminder was being created" if current.fetch("id") != work.fetch("id")
      end
      save(fresh, "work" => current.merge("schedule_id" => created.schedule.public_id))
    end

    def deliver_pending(row)
      work = row.value.fetch("work")
      pending = work["pending_notice"]
      return row unless pending

      receipt = @notifier.deliver(idempotency_key: pending.fetch("key"), recipient: work.fetch("assignee"), message: pending.fetch("message"))
      save(row, "work" => work.merge("pending_notice" => nil, "notice_count" => work.fetch("notice_count") + 1,
        "last_notice" => receipt.merge("recorded_at" => @clock.call.iso8601),
        "next_reminder_at" => (@clock.call + @configuration.reminder).iso8601))
    end

    def work(row, args)
      value = row&.value&.fetch("work", nil)
      raise Error, "this cleaning work item is unavailable" unless value && value.fetch("id") == args.fetch("work_id")

      value
    end

    def remind(row, args)
      current = work(row, args)
      return row if current.fetch("status") == "completed" || current["reminders_cancelled"]
      return row if !current["pending_notice"] && @clock.call < Time.iso8601(current.fetch("next_reminder_at"))

      unless current["pending_notice"]
        pending = { "key" => "#{current.fetch("id")}:reminder:#{current.fetch("next_reminder_at")}",
          "message" => "Cleaning work #{current.fetch("id")} is still #{current.fetch("status")}; acknowledgement does not confirm completion." }
        row = save(row, "work" => current.merge("pending_notice" => pending))
      end
      deliver_pending(row)
    end

    def acknowledge(row, args)
      current = work(row, args)
      return row if current["acknowledgement"] || current.fetch("status") == "completed"

      evidence = evidence(args, current)
      save(row, "work" => current.merge("status" => "acknowledged", "acknowledgement" => evidence))
    end

    def complete(row, args)
      current = work(row, args)
      unless current.fetch("status") == "completed"
        raise Error, "completion requires a separate acknowledgement" unless current["acknowledgement"]

        current = current.merge("status" => "completed", "completion" => evidence(args, current), "pending_notice" => nil)
        row = save(row, "work" => current)
      end
      @jobs.cancel(current.fetch("schedule_id")) if current["schedule_id"]
      row
    end

    def evidence(args, current)
      raise Error, "evidence must name the configured worker" unless args.fetch("worker") == current.fetch("assignee")
      raise Error, "the evidence source is not configured" unless @configuration.sources.include?(args.fetch("source"))

      { "worker" => args.fetch("worker"), "source" => args.fetch("source"), "note" => args.fetch("note"), "recorded_at" => @clock.call.iso8601 }
    end

    def fresh?(stamp) = @clock.call - Time.iso8601(stamp.fetch("observed_at")) <= @configuration.freshness

    def projection(row, room)
      document = row&.value || {}
      work = document["work"]
      { "room" => room, "enabled" => @configuration.enabled, "actions_allowed_now" => @configuration.actions_allowed?(@clock.call),
        "observation" => freshness_projection(document["observation"]), "worker_location" => freshness_projection(document["location"]),
        "cleaning" => work&.slice("id", "status", "assignee", "assigned_at", "triage", "notice_count", "last_notice", "acknowledgement", "completion", "schedule_id", "reminders_cancelled") }
    end

    def freshness_projection(value)
      value && value.merge("freshness" => fresh?(value) ? "recent_report" : "stale_report")
    end
end

SCHEMA = {
  "type" => "object", "properties" => {
    "action" => { "type" => "string", "enum" => %w[status observe check_in triage remind acknowledge complete cancel_reminders] },
    "room" => { "type" => "string", "minLength" => 1, "maxLength" => 100 },
    "work_id" => { "type" => "string", "minLength" => 1, "maxLength" => 100 },
    "source_conversation" => { "type" => "string", "minLength" => 1, "maxLength" => 100 },
    "event_id" => { "type" => "string", "minLength" => 1, "maxLength" => 128 },
    "source" => { "type" => "string", "minLength" => 1, "maxLength" => 100 },
    "observed_at" => { "type" => "string", "minLength" => 1, "maxLength" => 100 },
    "finding" => { "type" => "string", "enum" => %w[untidy clear] },
    "worker" => { "type" => "string", "minLength" => 1, "maxLength" => 100 },
    "reported_room" => { "type" => "string", "minLength" => 1, "maxLength" => 100 },
    "reason" => { "type" => "string", "minLength" => 1, "maxLength" => 1000 },
    "note" => { "type" => "string", "minLength" => 1, "maxLength" => 1000 },
  }, "required" => %w[action room], "additionalProperties" => false,
  "allOf" => [
    { "if" => { "properties" => { "action" => { "enum" => %w[observe check_in] } } }, "then" => { "required" => %w[event_id source observed_at] } },
    { "if" => { "properties" => { "action" => { "const" => "observe" } } }, "then" => { "required" => ["finding"] } },
    { "if" => { "properties" => { "action" => { "const" => "check_in" } } }, "then" => { "required" => %w[worker reported_room] } },
    { "if" => { "properties" => { "action" => { "const" => "triage" } } }, "then" => { "required" => ["reason"] } },
    { "if" => { "properties" => { "action" => { "enum" => %w[remind acknowledge complete cancel_reminders] } } }, "then" => { "required" => ["work_id"] } },
    { "if" => { "properties" => { "action" => { "enum" => %w[acknowledge complete] } } }, "then" => { "required" => %w[worker source note] } },
  ],
}.freeze

module HouseholdLedger
  NAME = "personal.household-ledger".freeze

  def self.register(api)
    raise Error, "household coordination requires an agent address" unless api.serves?(:agent)

    configuration = Configuration.parse(api.configuration)
    member_plane = api.host.member_plane
    tool_name = api.tool_name("household_cleaning")
    klass = Class.new do
      const_set(:NAME, "household_cleaning".freeze)
      const_set(:DESCRIPTION, "Coordinate configured public-room cleaning from sourced fixture observations. Observe never dispatches; triage requires a fresh observation and permitted period. Acknowledgement and completion require separate evidence. Notices are simulated by the fixture adapter. Status is a domain projection, not raw storage.".freeze)
      const_set(:SCHEMA, Ractor.make_shareable(SCHEMA))
      const_set(:EFFECT_PROFILE, { "kind" => "write", "destructive" => true, "effect_scope" => "closed", "idempotency" => "keyed", "reconciliation" => "lookup" }.freeze)
      const_set(:TIMEOUT_MS, 30_000)
      define_method(:initialize) { |env:| @env = env }
      define_method(:call) do |args|
        if args["source_conversation"] && args.fetch("action") != "remind"
          raise Error, "only a scheduled reminder can address its source conversation"
        end
        session = Session.new(member_plane: member_plane, source_conversation: args["source_conversation"], room: args.fetch("room"), work_id: args["work_id"])
        value = Ledger.new(configuration: configuration, session: session, tool_name: tool_name).call(args)
        files = []
        if args.fetch("action") == "complete"
          path = File.join(@env.ensure_artifacts_dir!, "cleaning-#{value.fetch("cleaning").fetch("id")}.json")
          File.write(path, JSON.pretty_generate(value))
          files << path
        end
        Rho::Runner::Result.new(content: JSON.generate(value), files: files, files_required: !files.empty?)
      rescue Error, Rho::Extensions::Schedules::Session::Unavailable, CybrosAgent::Error => error
        Rho::Runner::Result.error(error.message)
      end
    end
    api.register_tool(klass, serves: :agent)
  end
end
