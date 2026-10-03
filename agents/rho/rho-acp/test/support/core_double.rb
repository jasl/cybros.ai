module RhoAcpTest
  # THE CORE DOUBLE: a small in-process fake answering `Rho::Core`'s
  # primitives from a script, recording every call — the surface is
  # driven against it in the unit suite (the e2e lane is the real
  # witness; no daemon boots here). Each primitive answers what the test
  # scripted, raises the `Rho::Core::Refused` a test queued under
  # `refusals` (the sentence, its code and its status — the surface reads
  # the code), and appends `[name, args, kwargs]` to `calls`.
  #
  # `loop_events` plays the frames scripted under `events[conversation]`:
  # an Array of FOLLOWS, each an Array of `[type, payload]` frames, one
  # follow consumed per subscription (a re-join reads the next); or a
  # `Queue` a test feeds live (`[type, payload]`; `:closed` ends it) for
  # the cases that need a follow open while the client answers.
  class CoreDouble
    Settings = Struct.new(:mode, :default_model, keyword_init: true)

    attr_reader :calls
    attr_accessor :daemon, :connected, :status_state, :status_connection, :events, :rows, :tasks, :say_answers,
      :turns_pages, :transcripts, :skills_document, :known_models, :ceremony, :refusals, :settings, :attach_answer,
      :open_answers, :environment_answers

    def initialize(mode: "full", default_model: "openrouter/default-model")
      @calls = []
      @daemon = { "endpoint" => "http://127.0.0.1:1", "bearer" => "b", "version" => 1 }
      @connected = true
      @status_state = "active"
      @events = {}
      @rows = {}
      @tasks = {}
      @say_answers = []
      @turns_pages = []
      @transcripts = {}
      @skills_document = { "user" => [], "workspace" => [], "project" => nil }
      @known_models = []
      @ceremony = {}
      @refusals = {}
      @settings = Settings.new(mode: mode, default_model: default_model)
      @attach_answer = {}
      @open_answers = []
      @environment_answers = []
      @conversations = 0
      @lock = Mutex.new
    end

    def config = @settings

    # ---- the daemon ----

    def running_daemon
      record(:running_daemon)
      @daemon
    end

    def require_daemon
      record(:require_daemon)
      @daemon || raise(Rho::Error, "no local daemon is running; start one with `rho server`")
    end

    def stored_connection
      record(:stored_connection)
      @connected ? { "user_public_id" => "usr_1" } : nil
    end

    # `status_connection` is the ceremony document the daemon status
    # carries while one is in flight; nil answers none, as the daemon does.
    def status_document(_daemon)
      record(:status_document)
      { "state" => @status_state, "mode" => @settings.mode, "connection" => @status_connection }.compact
    end

    def start_ceremony(_daemon)
      record(:start_ceremony)
      @ceremony
    end

    def failure_message(document)
      error = document["error"]
      (error.is_a?(Hash) ? error["message"] : error).to_s
    end

    # ---- conversations ----

    def open_conversation(**kwargs)
      record(:open_conversation, **kwargs)
      refuse!(:open_conversation)
      @open_answers.shift || { "conversation" => { "public_id" => "cnv_#{@conversations += 1}" } }
    end

    def attach(public_id, live: true, host_type: nil)
      record(:attach, public_id, live: live, host_type: host_type)
      refuse!(:attach)
      @attach_answer
    end

    def loop_row(public_id)
      record(:loop_row, public_id)
      refuse!(:loop_row)
      @rows.fetch(public_id) { raise Rho::Error, "this daemon is not following #{public_id}" }
    end

    def say(public_id, text, **kwargs)
      record(:say, public_id, text, **kwargs)
      refuse!(:say)
      answer = @say_answers.shift || { "turn" => { "public_id" => "trn_1" }, "loop" => { "public_id" => "alp_1" } }
      answer.respond_to?(:call) ? answer.call(public_id, text, **kwargs) : answer
    end

    def loop_events(public_id, deadline: nil)
      record(:loop_events, public_id, deadline: deadline)
      refuse!(:loop_events)
      source = @events[public_id]
      raise Rho::Error, "this daemon is not following #{public_id}" if source.nil?

      if source.is_a?(Queue)
        while (frame = source.pop) != :closed
          yield(*frame)
        end
      else
        follow = source.shift
        raise Rho::Error, "no follow scripted for #{public_id}" if follow.nil?

        follow.each { |type, payload| yield(type, payload) }
      end
      nil
    end

    def task(public_id, task_key)
      record(:task, public_id, task_key)
      refuse!(:task)
      @tasks.fetch([public_id, task_key]) { raise Rho::Error, "no task #{task_key} on #{public_id}" }
    end

    %i[approve deny answer stop retry abandon compact].each do |verb|
      define_method(verb) do |*args, **kwargs|
        record(verb, *args, **kwargs)
        refuse!(verb)
        { "public_id" => args.first }
      end
    end

    def skills
      record(:skills)
      refuse!(:skills)
      @skills_document
    end

    def providers
      record(:providers)
      []
    end

    def model_facts(model)
      record(:model_facts, model)
      refuse!(:model_facts)
      { "known" => @known_models.include?(model), "tool_calls" => true }
    end

    def turns(public_id, after_position: nil, limit: nil)
      record(:turns, public_id, after_position: after_position, limit: limit)
      refuse!(:turns)
      @turns_pages.shift || { "turns" => [], "pagination" => { "has_more" => false } }
    end

    def transcript(public_id, limit: nil, before: nil, prefix: nil)
      record(:transcript, public_id, limit: limit, before: before, prefix: prefix)
      refuse!(:transcript)
      @transcripts.fetch(public_id) { { "rounds" => [], "has_older" => false } }
    end

    def bind_environment(public_id, **kwargs)
      record(:bind_environment, public_id, **kwargs)
      kwargs.each_key { |member| refuse!(:"bind_#{member}") }
      @environment_answers.shift || { "root" => kwargs[:root], "conversation" => public_id }
    end

    def environment
      record(:environment)
      { "root" => "/tmp" }
    end

    # ---- the script's helpers ----

    # The calls of one primitive, as `[args, kwargs]` pairs.
    def calls_of(name) = @lock.synchronize { @calls.select { |call| call.first == name }.map { |call| call.drop(1) } }

    def called?(name) = !calls_of(name).empty?

    # Queues one refusal for the next call of `name`: the daemon's
    # sentence, its code word (nil for an envelope-less refusal) and its
    # status — typed as the core raises it, so the surface under test
    # reads the code, never the sentence.
    def refuse(name, message, code:, status:)
      @lock.synchronize { (@refusals[name] ||= []) << [message, code, status] }
    end

    private

      def record(name, *args, **kwargs)
        @lock.synchronize { @calls << [name, args, kwargs] }
      end

      def refuse!(name)
        refusal = @lock.synchronize { @refusals[name]&.shift }
        return if refusal.nil?

        message, code, status = refusal
        raise Rho::Core::Refused.new(message, code: code, status: status)
      end
  end

  # THE FOLLOWER THAT LAGS THE VERB (`Turn.catch_up`): a row that keeps
  # answering `stale` for `reads` reads after the script armed it, then
  # `settled` — the kernel's feed item landing on the daemon a moment
  # after `answer`/`retry` returned. Deterministic: counted, never timed.
  class SettlingCore < CoreDouble
    def settle(public_id, reads:, stale:, settled:)
      @lock.synchronize { (@settling ||= {})[public_id] = { reads: reads, stale: stale, settled: settled } }
    end

    def loop_row(public_id)
      pending = @lock.synchronize { @settling&.dig(public_id) }
      return super if pending.nil?

      record(:loop_row, public_id)
      @lock.synchronize do
        pending[:reads] -= 1
        pending[:reads] >= 0 ? pending[:stale] : pending[:settled]
      end
    end
  end
end
