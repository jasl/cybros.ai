module TelegramScheduleSupport
  attr_reader :job_rows, :job_calls, :job_execution_rows
  attr_accessor :fail_job_create, :fail_job_control

  def prepare_schedules
    @job_rows, @job_keys, @job_calls, @job_execution_rows = {}, {}, [], {}
  end

  def schedule_answerer(isolated:) = isolated ? "group-agent" : nil

  def schedule_command(conversation_id, command:, **options)
    @job_calls << [command, conversation_id, options]
    case command.action
    when "create"
      key = options.fetch(:idempotency_key)
      id = @job_keys[key] ||= "01980000-0000-7000-8000-#{(@job_keys.length + 1).to_s.rjust(12, "0")}"
      row = @job_rows[id] ||= command.fields.transform_keys(&:to_s).merge(
        "public_id" => id, "conversation_public_id" => conversation_id, "status" => "active", "lock_version" => 0,
        "tool_names" => options[:tool_names], "answering_user_public_id" => options[:to] || "own-agent",
        "speaker_public_id" => options[:speaker_public_id], "model" => options[:model],
        "next_run_at" => command.fields.fetch(:rule)["run_at"] || command.fields.fetch(:rule)["starts_at"]
      )
      if @fail_job_create
        @fail_job_create = false
        raise Rho::ConnectionError, "job accepted but response lost"
      end
      row.except("conversation_public_id")
    when "list"
      schedules(conversation_id, workspace_public_id: options.fetch(:workspace_public_id))
    when "show"
      schedule(conversation_id, command.id, workspace_public_id: options.fetch(:workspace_public_id))
    when "history"
      schedule_executions(conversation_id, command.id, workspace_public_id: options.fetch(:workspace_public_id), **command.fields)
    when "edit", "pause", "resume", "cancel"
      schedule(conversation_id, command.id, workspace_public_id: options.fetch(:workspace_public_id))
      row = @job_rows.fetch(command.id)
      if command.action == "edit"
        row.merge!(command.fields.transform_keys(&:to_s))
      else
        row["status"] = { "pause" => "paused", "resume" => "active", "cancel" => "canceled" }.fetch(command.action)
      end
      row["lock_version"] += 1
      if @fail_job_control
        @fail_job_control = false
        raise Rho::ConnectionError, "job control accepted but response lost"
      end
      row.except("conversation_public_id")
    else
      raise ArgumentError, "unexpected job command"
    end
  end

  def schedules(conversation_id, after: nil, workspace_public_id:)
    { "schedules" => @job_rows.values.select { |row| row.fetch("conversation_public_id") == conversation_id }
        .map { |row| row.except("conversation_public_id") },
      "pagination" => { "next_after" => nil } }
  end

  def schedule(conversation_id, job_id, workspace_public_id:)
    row = @job_rows[job_id]
    return row.except("conversation_public_id") if row && row.fetch("conversation_public_id") == conversation_id

    raise Rho::Core::Refused.new("Job not found", code: "not_found", status: 404)
  end

  def schedule_executions(_conversation_id, job_id, after: nil, workspace_public_id:)
    rows = @job_execution_rows.fetch(job_id, [])
    index = after ? Integer(after.delete_prefix("execution-")) : 0
    page = rows.drop(index).first(100)
    cursor = page.empty? ? after : "execution-#{index + page.length}"
    { "executions" => page, "pagination" => { "next_after" => (cursor if index + page.length < rows.length), "last_cursor" => cursor } }
  end

  def read_only_schedule?(row, conversation_id:, workspace_public_id:)
    row.fetch("answering_user_public_id") == "group-agent" && row["tool_names"] &&
      (row.fetch("tool_names") - read_only_tool_names(conversation_id, group: true, workspace_public_id: workspace_public_id)).empty?
  end
end
