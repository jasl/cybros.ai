module E2E
  # Only the isolated world's operator handle is used. Production requests and
  # the configured cleanup job remain unchanged; this avoids a 90-day sleep.
  class HistoryRetentionFixture
    AGE = <<~RUBY.freeze
      loop = AgentLoop.find_by!(public_id: ARGV.fetch(0))
      abort("execution must have completed") unless loop.status == "completed"
      loop.update_columns(completed_at: 2.days.ago)
    RUBY
    PRUNE = <<~RUBY.freeze
      Conversations::PruneExecutionDetailsJob.perform_now(Account.sole.id, "loops")
    RUBY

    def age(public_id) = run(AGE, public_id)
    def prune = run(PRUNE)

    private

      def run(source, *arguments)
        handle = E2E.handle
        Tempfile.create(["history-retention", ".rb"]) do |script|
          script.write(source)
          script.flush
          status = E2E::ProcessRunner.run(Gem.ruby, "bin/rails", "runner", script.path, *arguments,
            env: handle.fetch("env"), chdir: handle.fetch("nexus_root"), timeout: 60)
          raise "History retention fixture failed" unless status.success?
        end
      end
  end
end
