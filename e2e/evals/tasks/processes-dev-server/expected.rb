# REACH: a `start_process` row completed. SUCCESS: the model fetched the
# file through the server (a bash row with curl, the reply carrying the
# content) AND the person's half held: the server listed under the loop,
# answering on the port, killed by `rho kill`, the port free after.
Expected.new(
  reach: lambda do |trace|
    started = trace.tool_rows("start_process").first
    next "the model never called start_process: #{trace.called.inspect}" if started.nil?

    started["status"] == "completed" ? true : "start_process #{started["key"]} #{started["status"]}: #{started.dig("error", "key").inspect}"
  end,
  success: lambda do |trace|
    next "no bash row fetched with curl: #{Predicates.bash_commands(trace).inspect}" unless Predicates.bash_commands(trace).any? { |c| c.include?("curl") }
    next "the reply does not carry the file's contents: #{trace.reply.strip[0, 80].inspect}" unless trace.reply.include?("hello from the project")
    next "rho processes lists no running server owned by the loop" unless trace.fact(:listed_under_loop) == true
    next "the server did not answer on its port" if trace.fact(:served_on_port).nil?
    next "rho kill did not end it" unless trace.fact(:killed) == true

    trace.fact(:port_freed) == true ? true : "the port still answers after rho kill"
  end,
  facts: { "log_under_home" => ->(trace) { trace.fact(:log_under_home) } }
)
