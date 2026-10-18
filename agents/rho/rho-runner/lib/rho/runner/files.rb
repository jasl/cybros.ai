module Rho
  class Runner
    # BYTES FROM THIS MACHINE, BY THE RULE THE TOOLS RESOLVE PATHS UNDER.
    #
    # Tool results name local paths, including image/PDF captures and
    # over-cap bash output spilled to a log. This module serves a person's
    # read of such a path: `locate` names the file with its
    # size and classified type (what `files_bytes` answers a person), and `bytes` reads it for a daemon's page (its
    # `/files/bytes` door). It lives in the runner gem because the reading
    # must happen where the file IS — on a runner elsewhere, `files_bytes`
    # runs here and the bytes travel as a capture.
    #
    # THERE IS NO PATH CONFINEMENT HERE, deliberately, and the reason is the
    # same one the tools state: a caller holding the bearer can author a loop
    # whose `bash` reads anything this user can read. A confined browse route
    # beside that door is theatre. Paths resolve EXACTLY as `ToolEnv#resolve`
    # does — expand against the environment root — because a panel and a
    # model that disagree about which file a path names are lying about what
    # the agent saw.
    #
    # WHAT IS CONFINED IS A PAGE'S RESPONSE. An inline answer is limited to a
    # classified type and capped; anything else is an attachment. The policy
    # header that keeps those bytes from becoming active content is the
    # daemon's to add: it knows the origin it serves them into.
    module Files
      # A viewer's transfer budget, which is not the model's context budget:
      # `Truncation::DEFAULT_MAX_BYTES` bounds what a tool result may cost a
      # prompt, and has no business bounding what a person may look at.
      INLINE_MAX_BYTES = 10 * 1024 * 1024

      # INLINE MEANS THE BROWSER RENDERS IT, so the list is what we are willing
      # to be rendered same-origin. `.html` is deliberately absent: serving it
      # inline is the single most expensive item in every reference that tried,
      # and a console on the operator's own machine loses nothing by handing it
      # over as an attachment instead.
      INLINE_TYPES = {
        ".png" => "image/png", ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg",
        ".gif" => "image/gif", ".webp" => "image/webp", ".avif" => "image/avif",
        ".svg" => "image/svg+xml", ".ico" => "image/x-icon",
        ".txt" => "text/plain; charset=utf-8", ".log" => "text/plain; charset=utf-8",
        ".json" => "application/json", ".md" => "text/plain; charset=utf-8",
      }.freeze
      ATTACHMENT_TYPE = "application/octet-stream".freeze

      # A file found: its resolved path, its size, and the type this module
      # classifies it as (the inline table's word, else the attachment's).
      Located = Data.define(:path, :size, :type)

      # A path that could not be read, as a status and a code — never the
      # errno's own words (below).
      Refusal = Data.define(:status, :code, :message)

      Answer = Data.define(:status, :headers, :body) do
        def ok? = status == 200
      end

      module_function

      # `root` is the environment's; `path` is whatever the transcript
      # showed, absolute or relative, resolved the way the tools resolve it.
      # Answers a `Located` or a `Refusal`.
      def locate(root:, path:)
        return Refusal.new(status: 400, code: "path_required", message: "A path is required") if path.to_s.empty?

        file = File.expand_path(path.to_s, root)
        stat = File.stat(file)
        return Refusal.new(status: 422, code: "not_a_file", message: "That path is not a file") unless stat.file?

        Located.new(path: file, size: stat.size, type: classify(file))
      rescue Errno::ENOENT, Errno::ENOTDIR
        Refusal.new(status: 404, code: "not_found", message: "No such file")
      rescue Errno::EACCES, Errno::EPERM
        Refusal.new(status: 403, code: "permission_denied", message: "This runner may not read that file")
      rescue Errno::ELOOP, Errno::ENAMETOOLONG, Errno::EINVAL
        Refusal.new(status: 422, code: "unreadable_path", message: "That path cannot be read")
      end

      # The type by the extension: the inline table's, else an attachment's.
      def classify(file) = INLINE_TYPES.fetch(File.extname(file).downcase, ATTACHMENT_TYPE)

      # The bytes for a page, whole, with the headers that say what they are
      # and how they may be shown; a refusal is its status and a JSON error.
      def bytes(root:, path:, download: false)
        located = locate(root: root, path: path)
        return refusal(located) if located.is_a?(Refusal)

        inline = !download && INLINE_TYPES.key?(File.extname(located.path).downcase)
        if inline && located.size > INLINE_MAX_BYTES
          return refusal(Refusal.new(status: 413, code: "too_large",
            message: "#{located.size} bytes is past the #{INLINE_MAX_BYTES}-byte inline limit; " \
                     "ask for it as a download"))
        end

        Answer.new(status: 200, headers: headers_for(located, inline), body: File.binread(located.path))
      rescue Errno::ENOENT, Errno::ENOTDIR
        refusal(Refusal.new(status: 404, code: "not_found", message: "No such file"))
      rescue Errno::EACCES, Errno::EPERM
        refusal(Refusal.new(status: 403, code: "permission_denied", message: "This runner may not read that file"))
      end

      # THE ERRNO NEVER CROSSES. A control server refuses to describe a 500
      # because "the description is the one thing likely to quote something
      # private", and this is the read most likely to touch a private path:
      # `Errno::EACCES … @ dir_initialize - /Users/somebody/vault` is a
      # disclosure with a status code on it.
      def refusal(refused)
        Answer.new(status: refused.status, headers: nil,
          body: { error: { code: refused.code, message: refused.message } })
      end

      def headers_for(located, inline)
        name = File.basename(located.path)
        {
          "content-type" => inline ? located.type : ATTACHMENT_TYPE,
          "content-length" => located.size.to_s,
          "content-disposition" =>
            "#{inline ? "inline" : "attachment"}; filename=\"#{name.gsub(/["\\]/, "_")}\"",
          "cache-control" => "private, no-store",
          "x-content-type-options" => "nosniff",
        }
      end
    end
  end
end
