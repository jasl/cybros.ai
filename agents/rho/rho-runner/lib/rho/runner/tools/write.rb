require "fileutils"

module Rho
  class Runner
    module Tools
      # Ported from pi's write.ts: create-or-overwrite a file, making parent
      # directories automatically. The filesystem mutation runs inside the
      # runner's per-path mutation queue so same-path writes and edits
      # serialize instead of interleaving. Reports content.bytesize — a
      # deliberate deviation from pi, which reports JS String#length (UTF-16
      # code units) and undercounts multibyte content.
      class Write
        NAME = "write"
        # Creates or overwrites files.
        EFFECT_PROFILE = {
          "kind" => "write", "destructive" => true, "effect_scope" => "closed",
          "idempotency" => "none", "reconciliation" => "none",
        }.freeze

        SCHEMA = Ractor.make_shareable({
          "type" => "object",
          "properties" => {
            "path" => { "type" => "string", "description" => "Path to the file to write (relative or absolute)" },
            "content" => { "type" => "string", "description" => "Content to write to the file" },
          },
          "required" => ["path", "content"],
        })

        DESCRIPTION =
          "Write content to a file. Creates the file if it doesn't exist, overwrites if it does. " \
          "Automatically creates parent directories.".freeze

        PROMPT_SNIPPET = "Create or overwrite files".freeze
        PROMPT_GUIDELINES = Ractor.make_shareable(["Use write only for new files or complete rewrites."])

        def initialize(env:)
          @env = env
        end

        # THE PORT BRANCH: a routed
        # path with `write` advertised lands in the editor's buffer — the
        # parent made on disk first (harmless; harbor mkdirs, Zed maps to a
        # worktree), the file itself never written there — and a write
        # NEVER falls to disk after the port was asked: `not_found` is the
        # disk for this call, every other answer is the model's to read.
        def call(args)
          ExecutionContext.current&.raise_if_cancelled!
          path = args.fetch("path")
          content = args.fetch("content")
          resolved = @env.resolve(path)
          port = FsPort.routed(@env, resolved, :write)

          @env.mutation_queue.with_lock(resolved) do
            ExecutionContext.current&.raise_if_cancelled!
            FileUtils.mkdir_p(File.dirname(resolved))
            ExecutionContext.current&.raise_if_cancelled!
            (port && through_port(port, resolved, content)) || to_disk(resolved, content)
          end
        rescue Errno::EISDIR
          Result.error("Path is a directory: #{path}")
        rescue Errno::EACCES
          Result.error("Permission denied: #{path}")
        rescue SystemCallError => e
          Result.error("Failed to write #{path}: #{e.message}")
        end

        private

        # THE RESOLVED PATH, not the argument. A relative path resolves
        # against the runner's root, which is not where the caller
        # thinks it is — so echoing the argument told a model its file
        # landed somewhere it did not, with no way to find out. The
        # resolved path is the only answer that cannot be a lie.
        def to_disk(resolved, content)
          File.write(resolved, content, encoding: Encoding::UTF_8)
          Result.ok("Successfully wrote #{content.bytesize} bytes to #{resolved}")
        end

        # A Result, or nil for `not_found` — the one answer that is the disk.
        def through_port(port, resolved, content)
          FsPort.ask(port) { port.write_text(resolved, content) }
          Result.ok("Successfully wrote #{content.bytesize} bytes to #{resolved} (written through #{port.client})")
        rescue FsPort::NotFound
          nil
        rescue FsPort::Refused => error
          Result.error("#{port.client}: #{error.message}")
        rescue FsPort::Unavailable
          Result.error("#{port.client} did not confirm the write; nothing was written")
        end
      end
    end
  end
end
