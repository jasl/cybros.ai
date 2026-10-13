require "fileutils"
require "shellwords"

module E2E
  # A PROJECT THE MODEL HAS NEVER SEEN, written fresh under a journey's home
  # and judged by its own suite: `run` is the acceptance command's output
  # and exit status (the verdict is the suite's, never the transcript's),
  # `unchanged?` is the diff that catches a model editing the specification
  # instead of the code, and `added_tests` counts what it wrote of its own.
  # `files` is what was written, so the two checks need no second copy.
  FixtureProject = Data.define(:root, :files) do
    def self.write(home, name, files)
      root = File.join(home, name)
      files.each do |path, contents|
        full = File.join(root, path)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, contents)
      end
      new(root: root, files: files.dup.freeze)
    end

    def run(command)
      output = `cd #{Shellwords.escape(root)} && #{command} 2>&1`
      [output.force_encoding(Encoding::UTF_8).scrub, $?]
    end

    def passes?(command) = run(command).last.success?

    def unchanged?(paths) = changed(paths).empty?

    # UTF-8 by name: the harness inherits the machine's empty locale.
    def changed(paths)
      paths.reject do |path|
        full = File.join(root, path)
        File.file?(full) && File.read(full, encoding: Encoding::UTF_8) == files.fetch(path)
      end
    end

    def added_tests(dir: "test")
      now = Dir[File.join(root, dir, "**", "*_test.rb")].sum { |file| test_methods(File.read(file, encoding: Encoding::UTF_8)) }
      then_ = files.sum { |path, contents| path.start_with?("#{dir}/") && path.end_with?("_test.rb") ? test_methods(contents) : 0 }
      now - then_
    end

    private

      def test_methods(source) = source.scan(/^\s*def test_/).size
  end
end
