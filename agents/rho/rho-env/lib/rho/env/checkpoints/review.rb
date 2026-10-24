require "tmpdir"

module Rho
  module Env
    module Checkpoints
      # The result carries the bytes, not pointers into the expiring checkpoint
      # store. Leave room for the checkpoint key and other result metadata.
      class Review
        MAX_BYTES = 48 * 1024
        MAX_PATCH_BYTES = 32 * 1024
        MAX_FILES = 200

        def initialize(root:, base:, rows:, deadline:, git:, clock:)
          @root, @base, @rows, @deadline, @git = root, base, rows, deadline, git
          @clock = clock
        end

        def document
          result = { "root" => @root, "base" => @base, "captured_at" => Time.now.utc.iso8601(6),
                     "files" => [], "truncated" => @rows.length > MAX_FILES }
          Dir.mktmpdir("rho-review") do |directory|
            git = Git.new(binary: @git, work_tree: directory, clock: @clock)
            @rows.first(MAX_FILES).each do |row|
              path = row.fetch("path")
              before, after, old_mode, new_mode = yield path
              file = row.merge(diff(git, directory, path, before, after, old_mode, new_mode))
              result.fetch("files") << file
              if JSON.generate(result).bytesize > MAX_BYTES
                file.delete("patch")
                file["state"] = "omitted" if file["state"] == "text"
              end
              if JSON.generate(result).bytesize > MAX_BYTES
                result.fetch("files").pop
                result["truncated"] = true
                break
              end
            end
          end
          result
        end

        private

          def diff(git, directory, path, before, after, old_mode, new_mode)
            texts = [before, after].compact.map { |bytes| bytes.dup.force_encoding(Encoding::UTF_8) }
            return { "state" => "binary" } if texts.any? { |text| !text.valid_encoding? || text.include?("\0") }

            File.binwrite(File.join(directory, "before"), before || "")
            File.binwrite(File.join(directory, "after"), after || "")
            outcome = git.call("diff", "--no-index", "--no-prefix", "--no-color", "--no-ext-diff", "--no-textconv",
              "--unified=3", "--", before ? "before" : File::NULL, after ? "after" : File::NULL, deadline: @deadline)
            return { "state" => "unavailable" } unless [0, 1].include?(outcome.status.exitstatus)

            patch = outcome.stdout.force_encoding(Encoding::UTF_8)
            # Git compares fixed temporary names. Only headers before the first
            # hunk are rewritten; user code resembling a header stays literal.
            header, body = patch.split(/(?=^@@ )/, 2)
            header = header.to_s.lines.reject { |line| line.start_with?("diff --git ", "index ", "--- ", "+++ ") }.join
            header << "old mode #{old_mode}\nnew mode #{new_mode}\n" if old_mode && new_mode && old_mode != new_mode
            patch = "#{header}--- #{before ? JSON.generate("a/#{path}") : "/dev/null"}\n" \
              "+++ #{after ? JSON.generate("b/#{path}") : "/dev/null"}\n#{body}"
            counts = { "additions" => body.to_s.lines.count { |line| line.start_with?("+") },
                       "deletions" => body.to_s.lines.count { |line| line.start_with?("-") } }
            if patch.bytesize > MAX_PATCH_BYTES
              counts.merge("state" => "too_large")
            else
              counts.merge("state" => "text", "patch" => patch)
            end
          end
      end
    end
  end
end
