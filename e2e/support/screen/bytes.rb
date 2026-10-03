require_relative "job"

module E2E
  module Screen
    # THE BYTES EACH ARM SENDS, read in its own tree by that tree's own code (`bytes_cli.rb`, run
    # under the tree's bundle): the compose bench's row and the task probe's entries, plain and under
    # `claude`, and every objective's prompt. Written under `<home>/bytes/<arm>/` and stamped as
    # `bytes.<arm>.<name>=<size> <sha256>`; the held-out check reads the stimuli from those files.
    module Bytes
      CLI = "support/screen/bytes_cli.rb".freeze
      STYLES = %w[nexus claude].freeze

      module_function

      def call(definition:, trees:, home:, command: CAPTURE)
        definition.arms.flat_map do |arm|
          root = trees.fetch(arm.tree)
          out, ok, err = command.call(["bundle", "exec", "ruby", CLI, *arguments(definition, arm, dir(home, arm.id))], chdir: File.join(root, "e2e"))
          raise Refused, "the #{arm.id} arm's bytes could not be read in #{root}: #{err.to_s.lines.last(3).join.strip}" unless ok

          out.lines(chomp: true).grep(/\A\S+ bytes=\d+ sha256=\h{64}\z/).map do |line|
            name, size, sha = line.split
            ["bytes.#{arm.id}.#{name}", "#{size.delete_prefix("bytes=")} #{sha.delete_prefix("sha256=")}"]
          end
        end
      end

      # An objective's prompt as the arm's tree wrote it.
      def objective(home, arm_id, instrument, id)
        File.read(File.join(dir(home, arm_id), "objective.#{instrument}.#{id}.txt"), encoding: Encoding::UTF_8)
      end

      def dir(home, arm_id) = File.join(home, "bytes", arm_id)

      def arguments(definition, arm, out)
        objectives = ->(instrument) { definition.cells.select { |cell| cell.instrument == instrument }.flat_map(&:objectives).uniq.join(",") }
        ["--out", out, "--rows", arm.row.to_s, "--styles", STYLES.join(","),
         "--compose-objectives", objectives.call("compose"), "--task-objectives", objectives.call("task")]
      end
      private_class_method :arguments
    end
  end
end
