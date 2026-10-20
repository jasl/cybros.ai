require "test_helper"

class CapturedEnvironmentTest < Minitest::Test
  def test_cold_placements_use_the_captured_root_and_never_fall_back
    Dir.mktmpdir("captured-env") do |tmp|
      root = File.realpath(tmp)
      a, b, c = %w[a b c].map { |name| File.join(root, name) }
      [a, b, c].each { |path| Dir.mkdir(path) }
      registry = Rho::Runner::Extensions::Loader.call(builtin: [Rho::Runner::Extensions::Coding]).registry
      zero = Rho::Runner::ToolEnv.new(root: a, artifacts_dir: File.join(root, "artifacts"))
      build = -> { Rho::Runner::Toolsets.new(registry: registry, zero: zero, work_dir: File.join(root, "work")) }
      task = CybrosAgent::Api::InboxTask.new(kind: "tool_call", run_public_id: "run", workspace_public_id: "ws",
        task_key: "write", tool_name: "write", tool_input: {}, tool_call_id: nil, started_at: nil,
        deadline_at: nil, timeout_ms: nil, claimed: true,
        executor_context: { "rho.environment" => { "root" => b, "directories" => [] } })
      2.times do
        placement = build.call.for(task)
        assert_equal b, placement.env.root
        Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new) do
          result = Rho::Runner::Tools::Write.new(env: placement.env).call("path" => "proof", "content" => "B")
          refute result.is_error, result.content
        end
      end
      assert_equal "B", File.read(File.join(b, "proof"))
      assert_empty Dir.children(a)
      subject = build.call
      other = task.with(executor_context: { "rho.environment" => { "root" => c } })
      assert_equal c, subject.for(other).env.root
      assert_equal b, subject.for(task).env.root
      with_directory = task.with(executor_context: { "rho.environment" => { "root" => b, "directories" => [c] } })
      assert_equal [c], subject.for(with_directory).env.directories
      FileUtils.rmdir(c)
      assert_raises(ArgumentError) { subject.for(with_directory) }
      FileUtils.rm_rf(b)
      error = assert_raises(ArgumentError) { subject.for(task) }
      assert_includes error.message, b
      assert_raises(ArgumentError) { subject.for(task.with(executor_context: nil)) }
      assert_empty Dir.children(a)
    end
  end
end
