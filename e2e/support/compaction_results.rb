module E2E
  module CompactionResults
    def compaction_prompt(project, marker)
      path = File.join(project, "current.txt")
      File.write(path, "#{marker}\n")
      arguments = CGI.escape(JSON.generate("command" => "cat #{path}"))
      "!mock usage=9000:5 tool_call=bash tool_args=#{arguments} -- say hi"
    end

    def assert_compaction_result_request(loop, marker)
      entries = agent_api("#{loop_path(loop)}/tasks/r2/request").fetch("request").fetch("entries")
      assert_equal 1, JSON.generate(entries).scan(marker).length,
        "the new result reaches its first consumer exactly once beside the summary"
    end
  end
end
