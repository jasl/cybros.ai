require "uri"

module E2E
  # Environment controls exposed by a complete rho application. The independent
  # library fixture implements the same operations through its owned process.
  module RhoEnvironmentControl
    def repoint(root)
      answer = control(:post, "/environment", body: { root: root })
      return answer unless answer.key?("error")

      raise "rho refused to point its tools at #{root}: #{answer["error"].inspect}"
    end

    def end_processes
      live = own_live_processes
      return if live.empty?

      live.each { |row| cli("kill", row.fetch("id")) }
      puts "processes: #{live.size} ended (#{live.map { |row| row["id"] }.join(", ")})"
      own_live_processes.each do |row|
        warn "the run's process #{row["id"]} (#{row["command"]}) still live after rho kill: the next run's prompt names it"
      end
    end

    private

      def own_live_processes
        runner = status.dig("identity", "runner_executor_public_id")
        raise "rho names no runner row of its own: its process table cannot be read without the relay" if runner.nil?

        document = control(:get, "/processes?runner=#{URI.encode_www_form_component(runner)}")
        raise "rho refused the process listing: #{document["error"].inspect}" if document.key?("error")

        document.fetch("processes").reject { |row| row["status"] == "exited" }
      end
  end
end
