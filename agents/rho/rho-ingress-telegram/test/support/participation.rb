require "support/runtime"

module TelegramParticipationSupport
  include TelegramRuntimeSupport

  class Bridge < TelegramRuntimeSupport::Bridge
    attr_reader :inference_requests, :participation_starts, :participation_cancels,
      :participation_records, :record_attempts
    attr_accessor :participation_ready, :participation_default_model,
      :fail_participation_start, :fail_participation_record

    def initialize
      super
      @inference_requests, @participation_records = {}, {}
      @participation_starts, @participation_cancels, @record_attempts = [], [], []
      @participation_ready = true
      @participation_default_model = "vendor/default"
    end

    def submit(id, **request)
      result = super
      result.fetch("input")["position"] = { "cursor" => "before-#{result.fetch("input").fetch("public_id")}", "sequence" => 0 }
      result
    end

    def participation_model = @participation_default_model

    def participation_context(id, latest_input_id:, position:, workspace_public_id:)
      return unless @participation_ready

      observation(id, workspace_public_id: workspace_public_id) + @participation_records.values.map { |row| "\nassistant: #{row.fetch(:text)}" }.join
    end

    def participation_start(**fields)
      @participation_starts << fields
      row = @inference_requests[fields.fetch(:idempotency_key)] ||= { "id" => "one-shot-#{@inference_requests.length + 1}", "status" => "queued" }
      if @fail_participation_start
        @fail_participation_start = false
        raise Rho::ConnectionError, "InferenceRequest accepted but response lost"
      end
      row.dup
    end

    def participation(id:, workspace_public_id:)
      @inference_requests.values.find { |row| row.fetch("id") == id }.dup
    end

    def cancel_participation(id:, workspace_public_id:)
      @participation_cancels << [id, workspace_public_id]
      @inference_requests.values.find { |row| row.fetch("id") == id }["status"] = "canceled"
      nil
    end

    def record_participation(id, **fields)
      @record_attempts << fields.merge(conversation_id: id)
      @participation_records[fields.fetch(:idempotency_key)] ||= fields.merge(conversation_id: id)
      if @fail_participation_record
        @fail_participation_record = false
        raise Rho::ConnectionError, "Assistant message accepted but response lost"
      end
      "recorded-input-#{@participation_records.keys.index(fields.fetch(:idempotency_key)) + 1}"
    end
  end

  def setup
    super
    @bridge = Bridge.new
    @runtime = runtime
  end

  private

    def group_message(id, text, **options)
      receive(telegram_message(id, text, chat: -10, topic: 4, date: @now.to_i, **options))
    end

    def enable_participation
      @client.admin = true
      group_message(1, "/observe on")
      group_message(2, "/mode active")
      @runtime.tick
      advance(3)
    end

    def advance(seconds = 5)
      @now += seconds
      @runtime.tick
    end

    def finish_participation(text = "A short useful reply", **fields)
      @bridge.inference_requests.values.last.merge!("status" => "completed", "text" => JSON.generate("decision" => "reply", "text" => text), **fields)
    end

    def sent_texts
      @client.calls.filter_map { |method, fields| fields[:text] if method == "sendMessage" }
    end

    def group_room = @state.read.fetch("rooms").fetch("-10:4")
end
