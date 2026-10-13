require "test_helper"

class CodingDocumentsTest < Minitest::Test
  include RunnerTest::Helpers

  Coding = Rho::Runner::Extensions::Coding

  def test_an_installed_workspace_guide_is_discoverable_and_loads_outside_the_project
    with_tool_env do |env, root|
      guide = File.join(File.dirname(root), "workspace-tools.md")
      File.write(guide, "# Workspace tools\n\nUse the prepared Python environment.\n")
      environment = Rho::Runner::Environment.local(root: root)

      documents = Coding.documents(environment, guide_path: guide)
      assert_equal ["workspace-tools"], documents.map { |row| row.fetch("name") }
      assert_includes documents.first.fetch("description"), "Office"

      result = skill_tool(env, guide).call("name" => "workspace-tools")
      refute_predicate result, :is_error
      assert_equal "# Workspace tools\n\nUse the prepared Python environment.", result.content
    end
  end

  def test_a_missing_or_removed_guide_is_not_advertised_or_loaded
    with_tool_env do |env, root|
      guide = File.join(File.dirname(root), "workspace-tools.md")
      environment = Rho::Runner::Environment.local(root: root)
      tool = skill_tool(env, guide)

      assert_empty Coding.documents(environment, guide_path: guide)
      assert_equal "skill_unknown: workspace-tools", tool.call("name" => "workspace-tools").content

      File.write(guide, "Prepared tools\n")
      assert_equal 1, Coding.documents(environment, guide_path: guide).length
      assert_equal "skill_unknown: another-guide", tool.call("name" => "another-guide").content
      File.unlink(guide)

      result = tool.call("name" => "workspace-tools")
      assert_predicate result, :is_error
      assert_equal "skill_unknown: workspace-tools", result.content
      assert_empty Coding.documents(environment, guide_path: guide)
    end
  end

  def test_the_announced_roots_project_skill_overrides_the_installed_guide_after_binding
    with_tool_env do |env, root|
      guide = File.join(File.dirname(root), "workspace-tools.md")
      File.write(guide, "Image defaults\n")
      skill_dir = File.join(root, ".agents", "skills", "workspace-tools")
      FileUtils.mkdir_p(skill_dir)
      File.write(File.join(skill_dir, "SKILL.md"),
        "---\nname: workspace-tools\ndescription: Project-specific tooling.\n---\nUse this project's tools.\n")
      bound_root = File.join(root, "child")
      FileUtils.mkdir_p(bound_root)
      bound_env = Rho::Runner::ToolEnv.new(
        root: bound_root, documents_root: root, artifacts_dir: env.artifacts_dir
      )

      documents = Coding.documents(Rho::Runner::Environment.local(root: root), guide_path: guide)
      assert_equal [{ "name" => "workspace-tools", "description" => "Project-specific tooling." }], documents

      result = skill_tool(bound_env, guide).call("name" => "workspace-tools")
      refute_predicate result, :is_error
      assert_equal "Use this project's tools.\n\n#{format(Coding::FILES_LINE, skill_dir)}", result.content
    end
  end

  private

    def skill_tool(env, guide)
      Rho::Runner::Tools::Skill.new(env: env,
        loaders: ->(name, tool_env) { Coding.load(name, tool_env, guide_path: guide) })
    end
end
