# Loaded only by the explicitly invoked task operation benchmark.
class TaskOperationGrowthMetrics
  def initialize
    @phases = Hash.new { |phases, name| phases[name] = [] }
    @owner = Thread.current
    @active = []
    @sql = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      next unless Thread.current == @owner
      next if payload[:name].in?(%w[SCHEMA TRANSACTION])

      @active.each do |row|
        row[payload[:cached] ? :cache_hits : :queries] += 1
        row[:rows] += payload[:row_count].to_i
      end
    end
    @lock = ActiveSupport::Notifications.monotonic_subscribe("sql.active_record") do |_, start, finish, _, payload|
      next unless Thread.current == @owner
      next if payload[:name].in?(%w[SCHEMA TRANSACTION])

      @active.each do |row|
        row[:sql_ms] += (finish - start) * 1_000
        next unless payload.fetch(:sql).include?("FOR UPDATE")

        row[:lock_queries] += 1
        row[:lock_sql_ms] += (finish - start) * 1_000
      end
    end
    @records = ActiveSupport::Notifications.subscribe("instantiation.active_record") do |*, payload|
      next unless Thread.current == @owner

      @active.each { |row| row[:records] += payload.fetch(:record_count) }
    end
  end

  def capture(name)
    row = %i[queries cache_hits rows records sql_ms lock_queries lock_sql_ms].index_with { 0 }
    @active << row
    allocated = GC.stat(:total_allocated_objects)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
  ensure
    row[:elapsed_ms] = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000
    row[:allocations] = GC.stat(:total_allocated_objects) - allocated
    @active.pop
    @phases[name] << row
  end

  def add(name, row)
    @phases[name] << row
  end

  def summary
    @phases.transform_values do |rows|
      rows.first.keys.index_with do |key|
        values = rows.map { |row| row.fetch(key) }.sort
        { total: values.sum.round(3), p50: values[(values.length * 0.50).ceil - 1].round(3),
          p95: values[(values.length * 0.95).ceil - 1].round(3), max: values.last.round(3) }
      end.merge(count: rows.length)
    end
  end

  def close
    [@sql, @lock, @records].each { |subscriber| ActiveSupport::Notifications.unsubscribe(subscriber) }
  end
end

# Service time is nested inside HTTP time; these totals must never be added.
%w[Submit Observe].each do |name|
  Executors::TaskOperations.const_get(name).prepend(Module.new do
    define_method(:call) do
      metrics = Thread.current[:task_operation_growth_metrics]
      return super() unless metrics

      metrics.capture("service_#{name.downcase}") { super() }
    end
  end)
end
