require "json"

module E2E
  # A `bash` step running `printf OUTPUT`, as the kernel delivers its result: the `<call>` line names
  # the command, and the body is the line after it. A journey asserts the whole envelope, since an
  # `assert_includes` of the output alone passes on the call line with no result delivered.
  module PrintedEnvelope
    # The element the kernel names a tool tip's call with — the harness's ONE spelling of it, which
    # the journeys check against the kernel's bytes, so a count that reads the element
    # (`Evals::Trace#leaked_calls`) moves with them.
    CALL = "<call>".freeze
    CALL_END = CALL.sub("<", "</").freeze

    module_function

    def of(task_key, output)
      "<task_result task=\"#{task_key}\" status=\"completed\">\n" \
        "#{CALL}bash #{JSON.generate("command" => "printf #{output}")}#{CALL_END}\n#{output}\n</task_result>"
    end
  end
end
