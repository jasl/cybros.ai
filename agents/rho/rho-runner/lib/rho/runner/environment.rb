require "timeout"

module Rho
  class Runner
    # WHAT THE MODEL IS TOLD ABOUT WHERE ITS TOOLS OPERATE.
    #
    # Distinct from `ToolEnv`, and the two are easy to confuse: `ToolEnv`
    # is what a tool EXECUTES against — a root, an artifacts directory, a
    # mutation queue. This is what a model is TOLD. One is behaviour, one
    # is a sentence.
    #
    # EVERY FIELD IS OPTIONAL AND NONE OF THEM CONSTRAINS ANYTHING. A path
    # outside all of them still works, because the tools decline path
    # confinement on purpose — rho reads and writes the user's real files,
    # and working on one project from inside another is an ordinary thing
    # to do rather than an escape. So this is a statement of what happens
    # to be known, never a boundary, and nothing anywhere refuses on it.
    #
    # `root` is the one fact that always exists: it is where a bare
    # relative path lands, so a model that is told nothing else still
    # needs it to predict what `read("a.rb")` will open. `directories` is
    # the rest of a conversation's ROOT SET: the
    # directories a person bound beside the root (`--also`), told in one
    # line; the conventions walk still starts at the root.
    Environment = Data.define(:root, :directories, :working_directory, :branch, :worktree, :platform) do
      def initialize(directories: [], working_directory: nil, branch: nil, worktree: nil, platform: nil, **)
        super
      end

      class << self
        # Discovers what it can and states the rest as unknown. A
        # directory that is not a checkout simply has no branch — that is
        # not an error and does not stop anything.
        def local(root:, directories: [], working_directory: nil, git: Git)
          directory = working_directory && File.expand_path(working_directory)
          new(
            root: File.expand_path(root),
            directories: directories.map { |path| File.expand_path(path) }.freeze,
            working_directory: directory,
            branch: directory && git.branch(directory),
            worktree: directory && git.linked_worktree?(directory),
            platform: RbConfig::CONFIG["host_os"]
          )
        end
      end

      # A model that is told one directory and lands in another has been
      # told something useless unless it also knows they differ.
      def root_is_working_directory? = working_directory.nil? || working_directory == root

      def known? = !working_directory.nil? || !branch.nil?
    end

    # THE RECORD'S VALUE: rho's `store_entries` row at the conversation scope — `namespace
    # "rho.environment"`, `key "binding"` — carries `{"root", "directories", "anchor"}`, and
    # the compared tuple IS the value. The runner never reads the store: the HOST resolves
    # the record and the runner RECEIVES this value, in process through the daemon's
    # resolver or relayed over the executor call_tool as the hidden runner tool
    # `environment_bind`'s input. `anchor` is the conversation whose live members the
    # binding shares — itself when bound directly, the parent on a copy (a side's fork copy,
    # a spawned child's top-down copy).
    #
    # PARSED, NEVER TRUSTED: absent or malformed answers nil — a record a
    # person edited by hand through the SDK costs that conversation its
    # placement (zero, with the notice on the log), never the runner its
    # claim. `to_h` answers the value as the store spells it (string keys),
    # so a host compares and writes exactly what it read.
    # (Reopened rather than defined in the `Data.define` block: a block is
    # no lexical scope, and a constant assigned there lands on `Runner`.)
    Environment::Binding = Data.define(:root, :directories, :anchor)

    class Environment::Binding # rubocop:disable Style/ClassAndModuleChildren
      ROOT = "root".freeze
      DIRECTORIES = "directories".freeze
      ANCHOR = "anchor".freeze

      def self.parse(value)
        return nil unless value.is_a?(Hash)

        fields = value.transform_keys(&:to_s)
        root = fields[ROOT]
        directories = fields.fetch(DIRECTORIES, [])
        anchor = fields[ANCHOR]
        return nil unless root.is_a?(String) && !root.empty?
        return nil unless directories.is_a?(Array) && directories.all?(String)
        return nil unless anchor.nil? || anchor.is_a?(String)

        new(root: root, directories: directories.dup.freeze, anchor: anchor)
      end

      def to_h = { ROOT => root, DIRECTORIES => directories, ANCHOR => anchor }
    end

    # THE SMALLEST GIT READ THAT ANSWERS THE TWO QUESTIONS WORTH ASKING.
    # `git` may be absent, the directory may not be a checkout, and the
    # command may fail for reasons nobody here can fix — every one of
    # those answers nil, because a missing branch name must never cost a
    # loop its environment block.
    module Git
      TIMEOUT_SECONDS = 5

      module_function

      def branch(directory)
        name = capture(directory, "rev-parse", "--abbrev-ref", "HEAD")
        return nil if name.nil? || name == "HEAD"

        name
      end

      # A LINKED worktree, which is the one the screenshot's chip means: a
      # second checkout of the same repository, where `.git` is a file
      # pointing at the real directory rather than being one.
      def linked_worktree?(directory)
        common = capture(directory, "rev-parse", "--git-common-dir")
        own = capture(directory, "rev-parse", "--git-dir")
        return nil if common.nil? || own.nil?

        File.expand_path(common, directory) != File.expand_path(own, directory)
      end

      def capture(directory, *arguments)
        return nil unless File.directory?(directory)

        output = nil
        Timeout.timeout(TIMEOUT_SECONDS) do
          IO.popen(
            ["git", "-C", directory, *arguments],
            err: File::NULL
          ) { |io| output = io.read }
        end
        # `$?` rather than `$CHILD_STATUS`: this gem requires no English,
        # and a require for one alias is a dependency for a synonym.
        return nil unless $?&.success? # rubocop:disable Style/SpecialGlobalVars

        value = output.to_s.strip
        value.empty? ? nil : value
      rescue StandardError, Timeout::Error
        nil
      end
    end
  end
end
