require_relative "../test_helper"

class GitReviewTest < Minitest::Test
  include RunnerTest::Helpers

  def test_worktree_review_keeps_commit_paths_and_both_sides
    with_tool_env do |env, root|
      git(root, "init", "-q")
      File.write(File.join(root, "changed.txt"), "old\n")
      File.write(File.join(root, "deleted.txt"), "removed\n")
      git(root, "add", ".")
      git(root, "-c", "user.name=Test", "-c", "user.email=test@example.test", "commit", "-qm", "base")
      File.write(File.join(root, "changed.txt"), "new\n")
      File.unlink(File.join(root, "deleted.txt"))
      File.write(File.join(root, "new file.txt"), "created\n")
      tool = Rho::Env::Tools::GitReview.new(env: env)
      result = tool.call({})
      refute result.is_error, result.content
      review = result.structured_content
      assert_equal({ "changed.txt" => "M", "deleted.txt" => "D", "new file.txt" => "A" }, review.fetch("files").to_h { |row| [row["path"], row["status"]] })
      file = tool.call("base" => review["base"], "path" => "changed.txt").structured_content.fetch("file")
      assert_includes file["patch"], "-old\n+new\n"
      File.write(File.join(root, "changed.txt"), "newer\n")
      changed = tool.call("base" => review["base"], "path" => "changed.txt").structured_content.fetch("file")
      refute_equal file["fingerprint"], changed["fingerprint"]
      assert_includes file["patch"], "+new\n"
      assert_includes tool.call("path" => "new file.txt").structured_content.dig("file", "patch"), "+created\n"
      assert_includes tool.call("path" => "deleted.txt").structured_content.dig("file", "patch"), "-removed\n"
      File.binwrite(File.join(root, "binary"), "\x00\x01")
      assert_equal "binary", tool.call("path" => "binary").structured_content.dig("file", "state")
      File.write(File.join(root, "large"), "x" * 100_000)
      assert_equal "too_large", tool.call("path" => "large").structured_content.dig("file", "state")
      assert tool.call("path" => "missing").is_error
    end
  end

  def test_interleaved_reads_on_one_tool_keep_their_own_directory
    with_tool_env do |env, root|
      %w[first second].each do |name|
        directory = File.join(root, name)
        Dir.mkdir(directory)
        git(directory, "init", "-q")
        File.write(File.join(directory, "file.txt"), "original\n")
        git(directory, "add", ".")
        git(directory, "-c", "user.name=Test", "-c", "user.email=test@example.test", "commit", "-qm", "base")
        File.write(File.join(directory, "file.txt"), "#{name}\n")
      end
      tool = Rho::Env::Tools::GitReview.new(env: env)
      interleaved = nil
      tool.define_singleton_method(:git) do |*args|
        result = super(*args)
        if args.include?("--name-status") && !interleaved
          interleaved = true
          interleaved = call("root" => "second", "path" => "file.txt")
        end
        result
      end
      first = tool.call("root" => "first", "path" => "file.txt")
      refute first.is_error, first.content
      refute interleaved.is_error, interleaved.content
      assert_equal File.realpath(File.join(root, "first")), first.structured_content.fetch("root")
      assert_includes first.structured_content.dig("file", "patch"), "+first\n"
      assert_includes interleaved.structured_content.dig("file", "patch"), "+second\n"
    end
  end

  def test_non_git_and_unborn_head_are_explicit
    with_tool_env do |env, root|
      tool = Rho::Env::Tools::GitReview.new(env: env)
      assert_includes tool.call({}).content, "not_git"
      git(root, "init", "-q")
      assert_includes tool.call({}).content, "base_unavailable"
    end
  end

  def test_literal_paths_and_bounded_file_lists
    with_tool_env do |env, root|
      git(root, "init", "-q")
      File.write(File.join(root, "a[1].txt"), "original\n")
      File.write(File.join(root, "a1.txt"), "other\n")
      git(root, "add", ".")
      git(root, "-c", "user.name=Test", "-c", "user.email=test@example.test", "commit", "-qm", "base")
      File.write(File.join(root, "a[1].txt"), "selected\n")
      File.write(File.join(root, "a1.txt"), "not selected\n")
      tool = Rho::Env::Tools::GitReview.new(env: env)
      patch = tool.call("path" => "a[1].txt").structured_content.dig("file", "patch")
      assert_includes patch, "+selected"
      refute_includes patch, "not selected"
      300.times { |index| File.write(File.join(root, "file-#{index}-#{"x" * 150}"), "new\n") }
      result = tool.call({})
      refute result.is_error, result.content
      assert result.structured_content.fetch("truncated")
      files = result.structured_content.fetch("files")
      assert_operator files.length, :<=, 200
      assert files.all? { |row| File.file?(File.join(root, row.fetch("path"))) }
    end
  end

  private

    def git(root, *args)
      assert system("git", "-C", root, *args, out: File::NULL, err: File::NULL)
    end
end
