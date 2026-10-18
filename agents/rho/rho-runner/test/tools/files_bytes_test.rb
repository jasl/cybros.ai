require "test_helper"

# THE RUNNER'S CAPABILITY AS A TOOL: a file's
# bytes for a PERSON, answered as a capture the run uploads — the tool names
# the path and hands it over; it never reads the bytes into the result —
# and announced described to nobody.
class FilesBytesTest < Minitest::Test
  include RunnerTest::Helpers

  def tool(env) = Rho::Runner::Tools::FilesBytes.new(env: env)

  def test_it_names_the_file_with_its_type_and_size_and_hands_the_path_to_the_run
    with_tool_env do |env, root|
      File.binwrite(File.join(root, "shot.png"), "\x89PNG" + ("x" * 60))

      result = tool(env).call("path" => "shot.png")

      refute_predicate result, :is_error
      assert_equal "#{File.join(root, "shot.png")} (image/png, 64 bytes)", result.content
      assert_equal [File.join(root, "shot.png")], result.files, "the capture is the run's to upload"
      assert_nil result.structured_content
    end
  end

  def test_an_absolute_path_stands_and_a_relative_one_resolves_against_the_root
    with_tool_env do |env, root|
      File.write(File.join(root, "note.txt"), "hi")
      relative = tool(env).call("path" => "note.txt")
      absolute = tool(env).call("path" => File.join(root, "note.txt"))
      assert_equal relative.files, absolute.files
      assert_equal "text/plain; charset=utf-8", relative.content[/\((.+), 2 bytes\)/, 1]
    end
  end

  # A missing file is DATA the caller reads, with the module's code-shaped
  # sentence and never the errno; nothing is handed to the run.
  def test_a_missing_or_unreadable_path_is_an_error_naming_no_filesystem_detail
    with_tool_env do |env, root|
      missing = tool(env).call("path" => "nope.txt")
      assert_predicate missing, :is_error
      assert_equal "No such file", missing.content
      assert_empty missing.files
      directory = tool(env).call("path" => root)
      assert_predicate directory, :is_error
      assert_equal "That path is not a file", directory.content
    end
  end

  # DESCRIBED TO NOBODY: the constant is nil by declaration, the registry
  # entry says so, and the profile is `read`'s own — the seven load beside
  # it through the same door.
  def test_it_is_registered_undescribed_beside_the_seven
    registry = Rho::Runner::Extensions::Loader.call(builtin: [Rho::Runner::Extensions::Coding]).registry
    entry = registry.entries.find { |candidate| candidate.name == "files_bytes" }

    refute_nil entry
    assert_predicate entry, :undescribed?
    assert_nil entry.description
    assert_equal ["path"], entry.schema.fetch("required"), "the schema stands for the run's validation"
    assert_equal Rho::Runner::Tools::Read::EFFECT_PROFILE, entry.effect_profile
    refute registry.entries.find { |candidate| candidate.name == "read" }.undescribed?
  end
end
