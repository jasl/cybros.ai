# Run explicitly from nexus; ordinary test suites never load this measurement.
# MODEL_STREAMS=100 PROGRESS_KEYS=100 bundle exec ruby test/benchmarks/progress_cable_capacity.rb
# Creates and drops only its randomly named primary/queue/cable databases.
# Old history spans the real one-day retention edge: rows expire at the offered
# write rate while fresh frames take the real Action Cable / Solid Cable path.
require "securerandom"
require "fileutils"

run_id = "#{Process.pid}_#{SecureRandom.hex(4)}"
output = File.expand_path("../../tmp/progress-cable-#{run_id}", __dir__)
FileUtils.mkdir_p(output)
ENV["RAILS_ENV"] = "development"
ENV["RAILS_LOG_FILE"] = File.join(output, "rails.log")
ENV["SECRET_KEY_BASE"] = "progress-cable-benchmark-#{run_id}"
%w[DATABASE_URL PRIMARY_DATABASE_URL QUEUE_DATABASE_URL CABLE_DATABASE_URL].each { |key| ENV.delete(key) }
%w[primary queue cable].each do |role|
  key = role == "primary" ? "APP" : role.upcase
  ENV["RAILS_#{key}_DB_NAME"] = "cybros_nexus_cable_bench_#{run_id}_#{role}"
end

require_relative "../../config/environment"

class ProgressCableProbeJob < ApplicationJob
  def perform
  end
end

class ProgressCableCapacity
  Message = Data.define(:channel, :envelope)

  def initialize(output:)
    @output = output
    @model_streams = Integer(ENV.fetch("MODEL_STREAMS", "100"))
    @progress_keys = Integer(ENV.fetch("PROGRESS_KEYS", "100"))
    @write_seconds = Integer(ENV.fetch("WRITE_SECONDS", "180"))
    @recovery_seconds = Integer(ENV.fetch("RECOVERY_SECONDS", "150"))
    @setup_seconds = Integer(ENV.fetch("SETUP_SECONDS", "60"))
    @initial_backlog = Integer(ENV.fetch("INITIAL_BACKLOG", "120000"))
    @rate = @model_streams * 10 + @progress_keys * 4
    unless @model_streams.positive? && @progress_keys.positive? && @write_seconds.positive? &&
        @recovery_seconds.positive? && @setup_seconds >= 15 && @initial_backlog >= 0
      raise ArgumentError, "positive streams, keys and durations, SETUP_SECONDS >= 15, INITIAL_BACKLOG >= 0 required"
    end
    @samples = []
    @offered = 0
    @created = []
    @job_log = File.join(@output, "jobs.jsonl")
    @sample_log = File.join(@output, "samples.jsonl")
  end

  def run
    prepare_databases
    prepare_messages
    @start_at = Time.current + @setup_seconds
    seed_history
    start_worker
    baseline
    measure
    stop_worker
    summarize
  ensure
    stop_worker
    ActionCable.server.pubsub.shutdown
    ActiveRecord::Base.connection_handler.clear_all_connections!
    @created.reverse_each { |config| ActiveRecord::Tasks::DatabaseTasks.drop(config) }
  end

  private

    def prepare_databases
      # Assert the resolved names, including URL overrides, before the first DDL.
      configs = ActiveRecord::Base.configurations.configs_for(env_name: "development")
      configs.each do |config|
        key = config.name == "primary" ? "APP" : config.name.upcase
        unless config.database == ENV.fetch("RAILS_#{key}_DB_NAME")
          raise "benchmark database name was overridden for #{config.name}"
        end
      end
      configs.each do |config|
        ActiveRecord::Tasks::DatabaseTasks.create(config)
        @created << config
        unless config.name == "primary"
          ActiveRecord::Tasks::DatabaseTasks.load_schema(config, :ruby, Rails.root.join("db/#{config.name}_schema.rb"))
        end
      end
      Rails.logger.level = Logger::WARN
      ActiveRecord.verbose_query_logs = false
      ActiveJob.verbose_enqueue_logs = false
      @model_class = SolidCable::Message
      SolidQueue::Job
      SolidCableMessages::TrimJob
      @worker_options = Rails.application.config_for(:queue).fetch(:workers).sole.except(:processes)
      emit(event: "configuration", output: @output, ruby: RUBY_VERSION,
        rails: Rails.version, solid_cable: SolidCable::VERSION, solid_queue: SolidQueue::VERSION,
        postgres: @model_class.connection_pool.with_connection { |connection| connection.select_value("SHOW server_version") },
        model_streams: @model_streams, model_hz: 10, progress_keys: @progress_keys, progress_hz: 4,
        offered_rows_per_second: @rate, write_seconds: @write_seconds, recovery_seconds: @recovery_seconds,
        retention_seconds: SolidCable.message_retention.to_f, trim_batch_size: SolidCable.trim_batch_size,
        max_passes: SolidCableMessages::TrimJob::MAX_PASSES, trim_interval_seconds: 60,
        writer_batch_size: SolidCable.writer_batch_size, writer_batch_delay_seconds: SolidCable.writer_batch_delay.to_f,
        worker: @worker_options, initial_backlog: @initial_backlog)
    end

    def prepare_messages
      @models = Array.new(@model_streams) do
        host = SecureRandom.uuid_v7
        Message.new(channel: Nexus::RealtimeStreams.resource("conversation", host, "transcript"),
          envelope: { event: { type: "text_delta", turn_public_id: SecureRandom.uuid_v7,
            variant_public_id: SecureRandom.uuid_v7, run_public_id: SecureRandom.uuid_v7,
            task_key: "main", text: "A bounded model output delta with ordinary text. " * 3 } })
      end
      executor = SecureRandom.uuid_v7
      @progress = Array.new(@progress_keys) do |index|
        host = SecureRandom.uuid_v7
        frame = Executors::Progress.executor_progress(run_public_id: SecureRandom.uuid_v7,
          task_key: "inspect-#{index}", tool_name: "read", executor_public_id: executor,
          at: Time.current.utc.iso8601(3), payload: { "text_tail" => "Reading the next source region. " * 32,
            "structured" => { "completed" => 12, "total" => 100 } })
        Message.new(channel: Nexus::RealtimeStreams.resource("conversation", host, "progress"), envelope: { frame: frame })
      end
      @history = (@models.flat_map { |message| [message] * 10 } + @progress.flat_map { |message| [message] * 4 }).map do |message|
        { channel: message.channel, payload: ActiveSupport::JSON.encode(message.envelope),
          channel_hash: SolidCable::Message.channel_hash_for(message.channel) }
      end
      emit(event: "payloads", model_payload_bytes: ActiveSupport::JSON.encode(@models.first.envelope).bytesize,
        executor_payload_bytes: ActiveSupport::JSON.encode(@progress.first.envelope).bytesize)
    end

    def seed_history
      started = monotonic
      total = @initial_backlog + @rate * @write_seconds
      @seed_rows = total
      total.times.each_slice(1_000) do |ordinals|
        rows = ordinals.map do |ordinal|
          at = if ordinal < @initial_backlog
            @start_at - SolidCable.message_retention - 1.hour
          else
            @start_at - SolidCable.message_retention + (ordinal - @initial_backlog).fdiv(@rate)
          end
          @history.fetch(ordinal % @history.length).merge(created_at: at)
        end
        @model_class.insert_all!(rows)
      end
      @last_seed_id = @model_class.maximum(:id)
      @model_class.connection_pool.with_connection { |connection| connection.execute("ANALYZE solid_cable_messages") }
      emit(event: "seeded", rows: total, elapsed_seconds: monotonic - started,
        expiration_starts_at: @start_at.iso8601(6), expiration_rows_per_second: @rate)
      raise "seeding missed the start; increase SETUP_SECONDS" if Time.current >= @start_at - 10
    end

    def start_worker
      ActiveRecord::Base.connection_handler.clear_all_connections!
      observe_jobs
      worker = SolidQueue::Worker.new(**@worker_options)
      worker.mode = :fork
      @worker_pid = worker.start
    end

    def observe_jobs
      ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        if payload.fetch(:sql).start_with?('DELETE FROM "solid_cable_messages"')
          ActiveSupport::IsolatedExecutionState[:cable_benchmark_deleted] = payload.fetch(:affected_rows)
        end
      end
      ActiveSupport::Notifications.subscribe("perform.active_job") do |_, started, finished, _, payload|
        job = payload.fetch(:job)
        if ["SolidCableMessages::TrimJob", "ProgressCableProbeJob"].include?(job.class.name)
          row = { job: job.class.name, pass: job.arguments.first, started_at: started.iso8601(6),
            queue_delay_seconds: started - job.enqueued_at, duration_seconds: finished - started,
            deleted: ActiveSupport::IsolatedExecutionState.delete(:cable_benchmark_deleted).to_i,
            error: payload[:exception]&.first }
          File.open(@job_log, "a") { |file| file.puts(JSON.generate(row)) }
        end
      end
    end

    def baseline
      sleep [@start_at - Time.current - 10, 0].max
      while Time.current < @start_at
        ProgressCableProbeJob.perform_later
        sleep 0.2
      end
    end

    def measure
      @started = monotonic
      @model_ticks = @progress_ticks = 0
      next_trim = next_sample = next_probe = 0.0
      limit = @write_seconds + @recovery_seconds
      # The wall-clock limit bounds production and recovery even if the queue stops.
      while (elapsed = monotonic - @started) <= limit
        publish_through([elapsed, @write_seconds].min)
        if elapsed >= next_trim
          SolidCableMessages::TrimJob.perform_later
          next_trim += 60
        end
        if elapsed >= next_sample
          row = sample(elapsed)
          next_sample += 10
          break if elapsed > @write_seconds + 5 && row.fetch(:expired_rows).zero? && row.fetch(:unfinished_jobs).zero?
        end
        if elapsed >= next_probe
          ProgressCableProbeJob.perform_later
          next_probe += 0.2
        end
        sleep 0.005
      end
      ActionCable.server.pubsub.shutdown
      @final = sample(monotonic - @started)
    end

    def publish_through(elapsed)
      model_ticks = (elapsed * 10).floor
      (@model_ticks...model_ticks).each do
        @models.each { |message| ActionCable.server.broadcast(message.channel, message.envelope) }
        @offered += @models.length
      end
      @model_ticks = model_ticks
      progress_ticks = (elapsed * 4).floor
      (@progress_ticks...progress_ticks).each do
        @progress.each do |message|
          message.envelope.fetch(:frame)["at"] = Time.current.utc.iso8601(3)
          ActionCable.server.broadcast(message.channel, message.envelope)
        end
        @offered += @progress.length
      end
      @progress_ticks = progress_ticks
    end

    def sample(elapsed)
      cable = @model_class.connection_pool.with_connection do |connection|
        connection.select_one(<<~SQL)
          SELECT count(*) AS total_rows,
            count(*) FILTER (WHERE created_at < clock_timestamp() - #{SolidCable.message_retention.to_f} * interval '1 second') AS expired_rows,
            count(*) FILTER (WHERE id > #{@last_seed_id}) AS persisted_live_rows,
            pg_relation_size('solid_cable_messages') AS heap_bytes,
            pg_indexes_size('solid_cable_messages') AS index_bytes,
            pg_total_relation_size('solid_cable_messages') AS relation_bytes,
            pg_database_size(current_database()) AS database_bytes
          FROM solid_cable_messages
        SQL
      end
      row = { event: "sample", elapsed_seconds: elapsed.round(3), offered_rows: @offered,
        unfinished_jobs: SolidQueue::Job.where(finished_at: nil).count,
        failed_jobs: SolidQueue::FailedExecution.count,
        queue_database_bytes: SolidQueue::Record.connection_pool.with_connection do |connection|
          connection.select_value("SELECT pg_database_size(current_database())")
        end }.merge(cable.transform_keys(&:to_sym))
      @samples << row
      emit(row)
      row
    end

    def stop_worker
      if @worker_pid
        Process.kill("TERM", @worker_pid)
        _, status = Process.wait2(@worker_pid)
        @worker_pid = nil
        raise "Solid Queue worker exited #{status}" unless status.success?
      end
    end

    def summarize
      jobs = File.readlines(@job_log).map { |line| JSON.parse(line, symbolize_names: true) }
      trims = jobs.select { |job| job.fetch(:job) == "SolidCableMessages::TrimJob" }
      probes = jobs.select { |job| job.fetch(:job) == "ProgressCableProbeJob" }
      baseline, loaded = probes.partition { |job| Time.iso8601(job.fetch(:started_at)) < @start_at }
      summary = { event: "summary", output: @output, total_offered_rows: @offered,
        persisted_live_rows: @final.fetch(:persisted_live_rows), final_expired_rows: @final.fetch(:expired_rows),
        recovered: @final.fetch(:expired_rows).zero?, failed_jobs: @final.fetch(:failed_jobs),
        elapsed_seconds: @final.fetch(:elapsed_seconds),
        trim_passes: trims.length, deleted_rows: trims.sum { |job| job.fetch(:deleted) },
        trim_duration_seconds: distribution(trims.map { |job| job.fetch(:duration_seconds) }),
        trim_queue_delay_seconds: distribution(trims.map { |job| job.fetch(:queue_delay_seconds) }),
        baseline_probe_delay_seconds: distribution(baseline.map { |job| job.fetch(:queue_delay_seconds) }),
        loaded_probe_delay_seconds: distribution(loaded.map { |job| job.fetch(:queue_delay_seconds) }),
        maximum_sampled_writer_backlog: @samples.map { |row| row.fetch(:offered_rows) - row.fetch(:persisted_live_rows) }.max }
      emit(summary)
      File.write(File.join(@output, "summary.json"), JSON.pretty_generate(summary) + "\n")
      raise "fresh broadcasts were lost" unless @offered == @final.fetch(:persisted_live_rows)
      unless @final.fetch(:total_rows) == @seed_rows + @offered - summary.fetch(:deleted_rows)
        raise "row accounting differs from the trim DELETE observations"
      end
      raise "queue job failed" unless @final.fetch(:failed_jobs).zero? && jobs.all? { |job| job.fetch(:error).nil? }
    end

    def distribution(values)
      ordered = values.sort
      { count: ordered.length, p50: ordered[(ordered.length * 0.5).floor],
        p95: ordered[[(ordered.length * 0.95).ceil - 1, 0].max], max: ordered.last }
    end

    def emit(row)
      line = JSON.generate(row)
      puts line
      $stdout.flush
      File.open(@sample_log, "a") { |file| file.puts(line) }
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

ProgressCableCapacity.new(output: output).run
