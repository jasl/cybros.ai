require "digest"
require "timeout"

module Rho
  class Runner
    module Tools
      # A bounded, read-only view of the work tree. Each file is read separately;
      # the returned commit and patch remain the context of a later comment.
      class GitReview
        NAME = "git_review".freeze
        DESCRIPTION = nil
        EFFECT_PROFILE = Read::EFFECT_PROFILE
        MAX_BYTES = 32 * 1024
        MAX_FILES = 200
        SCHEMA = Ractor.make_shareable({
          "type" => "object",
          "properties" => {
            "root" => { "type" => "string", "maxLength" => 4096 },
            "base" => { "type" => "string", "pattern" => "^[0-9a-f]{40,64}$" },
            "path" => { "type" => "string", "maxLength" => 4096 },
          },
          "additionalProperties" => false,
        })
        ReadResult = Data.define(:text, :truncated, :status)

        def initialize(env:)
          @env = env
        end

        def call(args)
          @env.raise_if_cancelled!
          root = @env.resolve(args.fetch("root", "."))
          Timeout.timeout(10) do
            top = git(root, "rev-parse", "--show-toplevel")
            return Result.error("not_git: select a Git working directory") unless top.status.zero?

            root = top.text.chomp
            base = args["base"] || git(root, "rev-parse", "--verify", "HEAD").text.strip
            return Result.error("base_unavailable: a committed HEAD is required") unless base.match?(/\A[0-9a-f]{40,64}\z/)

            names = git(root, "diff", "--no-renames", "--name-status", "-z", base, "--")
            return Result.error("base_unavailable: the comparison commit is unavailable") unless names.truncated || names.status == 0

            untracked = git(root, "ls-files", "--others", "--exclude-standard", "-z")
            return Result.error("git_failed: unable to list untracked files") unless untracked.truncated || untracked.status == 0

            rows = complete_names(names).split("\0").each_slice(2).filter_map { |status, path| { "status" => status, "path" => path } if path }
            rows.concat(complete_names(untracked).split("\0").map { |path| { "status" => "A", "path" => path, "untracked" => true } })
            document = { "root" => root, "base" => base, "files" => rows.first(MAX_FILES),
                         "truncated" => names.truncated || untracked.truncated || rows.length > MAX_FILES }
            if args.key?("path")
              row = rows.find { |entry| entry.fetch("path") == args.fetch("path") }
              return Result.error("file_changed: refresh the changed files") unless row

              document["file"] = patch(root, row, base)
            end
            Result.ok("Git working directory compared with #{base}", document, title: "Git review")
          end
        rescue Timeout::Error
          Result.error("review_timeout: the Git read exceeded 10 seconds")
        rescue Errno::ENOENT
          Result.error("git_unavailable: Git or the working directory is unavailable")
        end

        private

          def complete_names(result)
            return result.text unless result.truncated

            boundary = result.text.b.rindex("\0")
            boundary ? result.text.byteslice(0, boundary + 1) : ""
          end

          def patch(root, row, base)
            options = ["diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--no-color", "--unified=3"]
            result = if row["untracked"]
              git(root, *options, "--no-index", "--", File::NULL, File.join(root, row.fetch("path")))
            else
              git(root, *options, base, "--", row.fetch("path"))
            end
            state = if result.truncated then "too_large"
            elsif ![0, 1].include?(result.status) then "unavailable"
            elsif !result.text.valid_encoding? then "binary"
            elsif result.text.include?("\nBinary files ") then "binary"
            else "text"
            end
            row.merge("state" => state, "patch" => state == "text" ? result.text : nil,
              "fingerprint" => Digest::SHA256.hexdigest(result.text))
          end

          def git(root, *args)
            child = Subprocess.start("git", "--literal-pathspecs", "-C", root, *args)
            text = +"".b
            truncated = false
            ExecutionContext.with_cancel_signal(-> { child.cancel }) do
              child.stdin.close
              while (chunk = child.stdout.readpartial(8192))
                @env.raise_if_cancelled!
                remaining = MAX_BYTES - text.bytesize
                text << chunk.byteslice(0, remaining)
                if chunk.bytesize > remaining
                  truncated = true
                  child.kill_and_reap
                  break
                end
              end
            rescue EOFError
              nil
            end
            ReadResult.new(text: text.force_encoding(Encoding::UTF_8), truncated: truncated, status: child.wait.exitstatus)
          ensure
            child&.cleanup
          end
      end
    end
  end
end
