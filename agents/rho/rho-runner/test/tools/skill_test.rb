require "test_helper"

# THE LOAD OF AN ANNOUNCED SKILL: the plane's `skill` tool over Coding's loader — the body
# under the frontmatter through `read`'s window, one line naming the base
# directory, the error `skill_unknown` for a name the root no longer holds
# — and announced described to nobody.
class SkillToolTest < Minitest::Test
  include RunnerTest::Helpers

  FILES_LINE = Rho::Runner::Extensions::Coding::FILES_LINE

  def tool(env)
    Rho::Runner::Tools::Skill.new(env: env, loaders: ->(name, e) { Rho::Runner::Extensions::Coding.load(name, e) })
  end

  def write_skill(root, directory, name, body, description: "How this project is deployed.")
    dir = File.join(root, directory, name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "SKILL.md"), "---\nname: #{name}\ndescription: #{description}\n---\n#{body}",
      encoding: "UTF-8")
    dir
  end

  def test_it_is_announced_described_to_nobody_with_a_schema_the_run_still_validates
    assert_equal "skill", Rho::Runner::Tools::Skill::NAME
    assert_nil Rho::Runner::Tools::Skill::DESCRIPTION
    assert Rho::Runner::Extensions::Tool.undescribed?(Rho::Runner::Tools::Skill)
    assert_equal ["name"], Rho::Runner::Tools::Skill::SCHEMA.fetch("required")
    assert_equal Rho::Runner::Tools::Read::EFFECT_PROFILE, Rho::Runner::Tools::Skill::EFFECT_PROFILE
    refute Rho::Runner::Tools::Skill::SCHEMA.key?("additionalProperties"), "a stray alias parameter is ignored, never refused"
  end

  def test_it_answers_the_body_without_the_frontmatter_and_names_the_base_directory
    with_tool_env do |env, root|
      dir = write_skill(root, ".agents/skills", "deploy-notes", "# Deploy\n\n1. Run `make release`.\n")

      result = tool(env).call("name" => "deploy-notes", "args" => "ignored")

      refute_predicate result, :is_error
      # `read`'s window: the body's lines joined, no trailing newline.
      assert_equal "# Deploy\n\n1. Run `make release`.\n\n#{format(FILES_LINE, dir)}", result.content
      assert_nil result.structured_content
    end
  end

  def test_the_first_directory_wins_and_a_body_of_nothing_is_the_directory_line_alone
    with_tool_env do |env, root|
      agents = write_skill(root, ".agents/skills", "commit-style", "agents body\n")
      write_skill(root, ".claude/skills", "commit-style", "claude body\n")
      write_skill(root, ".claude/skills", "empty", "")

      assert_equal "agents body\n\n#{format(FILES_LINE, agents)}", tool(env).call("name" => "commit-style").content
      assert_equal format(FILES_LINE, File.join(root, ".claude/skills/empty")), tool(env).call("name" => "empty").content
    end
  end

  # The body rides `read`'s window: a long skill is cut where `read` cuts
  # and carries `read`'s marker naming the FILE's line offsets, so the
  # model reads the rest by path.
  def test_a_long_body_is_cut_at_reads_window_with_reads_continuation_marker
    with_tool_env do |env, root|
      lines = (1..(Rho::Runner::Truncation::DEFAULT_MAX_LINES + 5)).map { |n| "line #{n}" }
      dir = write_skill(root, ".agents/skills", "long", lines.join("\n") + "\n")

      result = tool(env).call("name" => "long")

      refute_predicate result, :is_error
      assert result.content.start_with?("line 1\nline 2\n")
      # Four frontmatter lines: the window opens on line 5 of the FILE.
      last_shown = Rho::Runner::Truncation::DEFAULT_MAX_LINES + 4
      assert_includes result.content,
        "[Showing lines 5-#{last_shown} of #{lines.length + 4}. Use offset=#{last_shown + 1} to continue.]"
      assert result.content.end_with?("\n\n#{format(FILES_LINE, dir)}")
      assert_equal :lines, result.structured_content.dig("truncation", "truncated_by")
    end
  end

  # A name the root no longer holds — deleted since the announcement, or
  # never there — answers the one error word, the kernel's own envelope
  # shape; never a stale copy.
  def test_a_name_the_root_does_not_hold_is_skill_unknown
    with_tool_env do |env, root|
      write_skill(root, ".agents/skills", "deploy-notes", "# Deploy\n")

      result = tool(env).call("name" => "release-notes")
      assert_predicate result, :is_error
      assert_equal "skill_unknown: release-notes", result.content

      FileUtils.rm_rf(File.join(root, ".agents"))
      gone = tool(env).call("name" => "deploy-notes")
      assert_predicate gone, :is_error
      assert_equal "skill_unknown: deploy-notes", gone.content
    end
  end

  # A tool built outside the plane holds no loader and so no document.
  def test_without_loaders_every_name_is_skill_unknown
    with_tool_env do |env, root|
      write_skill(root, ".agents/skills", "deploy-notes", "# Deploy\n")
      result = Rho::Runner::Tools::Skill.new(env: env).call("name" => "deploy-notes")
      assert_predicate result, :is_error
      assert_equal "skill_unknown: deploy-notes", result.content
    end
  end
end
