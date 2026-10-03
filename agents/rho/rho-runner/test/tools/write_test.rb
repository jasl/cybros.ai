require "test_helper"

module RunnerTest
  class WriteToolTest < Minitest::Test
    include Helpers

    def test_creates_file_with_exact_content
      with_tool_env do |env, root|
        result = write_tool(env).call({ "path" => "hello.txt", "content" => "hello" })

        refute result.is_error
        assert_equal "Successfully wrote 5 bytes to #{File.join(root, "hello.txt")}", result.content
        assert_equal "hello", File.read(File.join(root, "hello.txt"))
      end
    end

    def test_overwrites_existing_file
      with_tool_env do |env, root|
        path = File.join(root, "existing.txt")
        File.write(path, "old content that is much longer than the replacement")

        result = write_tool(env).call({ "path" => "existing.txt", "content" => "new" })

        refute result.is_error
        assert_equal "new", File.read(path)
      end
    end

    def test_creates_nested_parent_directories
      with_tool_env do |env, root|
        result = write_tool(env).call({ "path" => "a/b/c/deep.txt", "content" => "nested" })

        refute result.is_error
        assert_equal "nested", File.read(File.join(root, "a", "b", "c", "deep.txt"))
      end
    end

    # THE RESOLVED PATH, not the argument. A relative path resolves against
    # the runner's root, which is not where a caller standing in a project
    # imagines it stands — so echoing the argument told a model its file
    # landed at `rel.txt` while it landed in a scratch root, with nothing
    # in the answer it could have used to find out.
    def test_a_relative_path_is_reported_where_it_actually_landed
      with_tool_env do |env, root|
        result = write_tool(env).call({ "path" => "rel.txt", "content" => "rooted" })

        refute result.is_error
        assert_equal "Successfully wrote 6 bytes to #{File.join(root, "rel.txt")}", result.content
        assert_path_exists File.join(root, "rel.txt")
      end
    end

    def test_reports_true_byte_count_for_multibyte_content
      with_tool_env do |env, root|
        result = write_tool(env).call({ "path" => "h.txt", "content" => "héllo" })

        refute result.is_error
        assert_equal "Successfully wrote 6 bytes to #{File.join(root, "h.txt")}", result.content
        assert_equal "héllo", File.read(File.join(root, "h.txt"), encoding: Encoding::UTF_8)
      end
    end

    def test_error_result_when_path_is_an_existing_directory
      with_tool_env do |env, root|
        FileUtils.mkdir_p(File.join(root, "adir"))

        result = write_tool(env).call({ "path" => "adir", "content" => "nope" })

        assert result.is_error
        assert_includes result.content, "adir"
        refute_includes result.content, "\n"
      end
    end

    def test_error_result_when_a_parent_component_is_a_file
      with_tool_env do |env, root|
        File.write(File.join(root, "flat.txt"), "not a directory")

        result = write_tool(env).call({ "path" => "flat.txt/child.txt", "content" => "nope" })

        assert result.is_error
        assert_includes result.content, "flat.txt/child.txt"
        refute_includes result.content, "\n"
      end
    end

    def test_write_waits_for_the_mutation_queue_lock_on_the_same_path
      with_tool_env do |env, root|
        path = File.join(root, "queued.txt")
        entered = Queue.new
        release = Queue.new
        holder = Thread.new do
          env.mutation_queue.with_lock(path) do
            entered << true
            release.pop
          end
        end
        entered.pop

        writer = Thread.new { write_tool(env).call({ "path" => "queued.txt", "content" => "after lock" }) }

        assert_nil writer.join(0.2), "write must serialize behind the mutation queue lock for the same path"

        release << true
        result = writer.value
        holder.join

        refute result.is_error
        assert_equal "after lock", File.read(path)
      end
    end

    def test_concurrent_writes_to_one_path_both_complete_and_file_stays_consistent
      with_tool_env do |env, root|
        tool = write_tool(env)
        first = "a" * 200_000
        second = "b" * 200_000

        threads = [first, second].map do |content|
          Thread.new { tool.call({ "path" => "contested.txt", "content" => content }) }
        end
        results = threads.map(&:value)

        assert(results.none?(&:is_error))
        final = File.read(File.join(root, "contested.txt"))
        assert_includes [first, second], final
      end
    end

    private

    def write_tool(env)
      Rho::Runner::Tools::Write.new(env:)
    end

    # THE PORT BRANCH: a routed
    # path with `write` advertised lands in the editor's buffer — the
    # parent is made on disk (harmless), the file is not written there —
    # and a write NEVER falls to disk after the port was asked.
    class WritePortTest < Minitest::Test
      include RunnerTest::Helpers

      FsPort = Rho::Runner::FsPort

      def test_a_routed_write_lands_in_the_buffer_and_names_the_client
        with_ported_env(RunnerTest::PortDouble.new) do |env, root|
          port = RunnerTest::PortDouble.new(client: "zed")
          result = ported(port, env, "lib/a.txt", "hello")
          path = File.join(root, "lib", "a.txt")

          refute result.is_error
          assert_equal "Successfully wrote 5 bytes to #{path} (written through zed)", result.content
          assert_equal [[:write, path, "hello"]], port.calls
          assert_equal "hello", port.buffers.fetch(path)
          assert File.directory?(File.dirname(path)), "the parent is made on disk"
          refute File.exist?(path), "the file itself is the buffer's"
        end
      end

      def test_a_port_not_serving_write_or_a_path_outside_the_set_is_the_disk
        with_ported_env(RunnerTest::PortDouble.new) do |env, root|
          read_only = RunnerTest::PortDouble.new(write: false)
          refute ported(read_only, env, "a.txt", "x").is_error
          assert_equal "x", File.read(File.join(root, "a.txt"))
          assert_empty read_only.calls

          outside = File.join(File.dirname(root), "outside.txt")
          port = RunnerTest::PortDouble.new
          refute ported(port, env, outside, "y").is_error
          assert_equal "y", File.read(outside)
          assert_empty port.calls
        end
      end

      # ---- the error table ----

      def test_not_found_falls_to_the_disk_for_this_call
        with_ported_env(RunnerTest::PortDouble.new) do |env, root|
          port = RunnerTest::PortDouble.new(fail: { write: FsPort::NotFound.new("no buffer") })
          result = ported(port, env, "a.txt", "on disk")

          refute result.is_error
          assert_equal "Successfully wrote 7 bytes to #{File.join(root, "a.txt")}", result.content
          assert_equal "on disk", File.read(File.join(root, "a.txt"))
          assert_empty port.dropped
        end
      end

      def test_editor_refused_is_an_error_naming_the_client_and_nothing_is_written
        with_ported_env(RunnerTest::PortDouble.new) do |env, root|
          port = RunnerTest::PortDouble.new(client: "zed", fail: { write: FsPort::Refused.new("read-only buffer") })
          result = ported(port, env, "a.txt", "x")

          assert result.is_error
          assert_equal "zed: read-only buffer", result.content
          refute File.exist?(File.join(root, "a.txt"))
          assert_empty port.dropped
        end
      end

      def test_cancelled_is_the_runners_cancel_path_and_nothing_is_written
        with_ported_env(RunnerTest::PortDouble.new) do |env, root|
          port = RunnerTest::PortDouble.new(fail: { write: FsPort::Cancelled.new("-32800") })
          assert_raises(Rho::Runner::ExecutionContext::Cancelled) { ported(port, env, "a.txt", "x") }
          refute File.exist?(File.join(root, "a.txt"))
        end
      end

      def test_unavailable_is_an_error_the_port_is_dropped_and_the_disk_is_never_written
        with_ported_env(RunnerTest::PortDouble.new) do |env, root|
          port = RunnerTest::PortDouble.new(client: "zed", fail: { write: FsPort::Unavailable.new("timeout") })
          result = ported(port, env, "a.txt", "x")

          assert result.is_error
          assert_equal "zed did not confirm the write; nothing was written", result.content
          refute File.exist?(File.join(root, "a.txt")), "a write never falls to disk after the port was asked"
          assert_equal ["timeout"], port.dropped
        end
      end

      private

      def ported(port, env, path, content)
        binding = Rho::Runner::ExecutionContext.current.binding
        context = Rho::Runner::ExecutionContext.new(tool_env: env, binding: binding, ports: ->(_anchor) { port })
        Rho::Runner::ExecutionContext.with(context) do
          Rho::Runner::Tools::Write.new(env:).call({ "path" => path, "content" => content })
        end
      end
    end
  end
end
