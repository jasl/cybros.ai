require "test_helper"
require "rho/gateway/commands"

class GatewayCommandsTest < Minitest::Test
  Update = Data.define(:group, :user_id) do
    def group? = group
    def chat_id = "-10"
    def topic_id = nil
  end

  class Runtime
    attr_reader :calls, :replies

    def initialize
      @calls, @replies = [], []
    end

    def owner?(update) = update.user_id == "owner"
    def observed?(_update) = @observed == true
    def can_observe?(_update) = true
    def set_observe(update, enabled, result:)
      @calls << [:set_observe, update, enabled]
      @observed = enabled
      result
    end
    def access_command(update, name, argument)
      @calls << [:access_command, update, name, argument]
      "Access updated."
    end

    def reply(update, text)
      @replies << [update, text]
    end

    def submit(update, text:, mode:)
      @calls << [:submit, update, { text: text, mode: mode }]
      reply(update, "Instructions accepted.")
    end

    def side_question(update, text)
      @calls << [:side_question, update, text]
      reply(update, "Side question accepted.")
    end

    def remind(update, expression:, text:)
      @calls << [:remind, update, { expression: expression, text: text }]
      reply(update, "Reminder scheduled.")
    end

    def queue_reschedule(update, number, expression)
      @calls << [:queue_reschedule, update, number, expression]
      "Request rescheduled."
    end
  end

  def setup
    @runtime = Runtime.new
    @commands = Rho::Gateway::Commands.new(@runtime)
    @update = Update.new(group: false, user_id: "person")
  end

  def test_steer_forwards_only_the_body_and_the_runtime_owns_its_receipt
    @commands.call(@update, "steer", "Keep the file.\nRun its focused test.")

    assert_equal [[:submit, @update, { text: "Keep the file.\nRun its focused test.", mode: "steer" }]], @runtime.calls
    assert_equal [[@update, "Instructions accepted."]], @runtime.replies
  end

  def test_steering_text_with_a_hyphenated_path_still_uses_the_current_task
    text = "docs/how-to-run-this-test.md needs its examples updated"
    @commands.call(@update, "steer", text)

    assert_equal [[:submit, @update, { text: text, mode: "steer" }]], @runtime.calls
  end

  def test_side_question_uses_its_own_runtime_operation_without_a_second_receipt
    @commands.call(@update, "btw", "What does this error mean?")

    assert_equal [[:side_question, @update, "What does this error mean?"]], @runtime.calls
    assert_equal [[@update, "Side question accepted."]], @runtime.replies
  end

  def test_empty_instruction_and_side_question_show_usage_without_admission
    @commands.call(@update, "steer", " \n\t")
    @commands.call(@update, "btw", "")

    assert_empty @runtime.calls
    assert_includes @runtime.replies[0].last, "/steer <text>"
    assert_includes @runtime.replies[1].last, "/btw <question>"
  end

  def test_reminder_and_reschedule_commands_preserve_text_and_use_the_runtime_policy
    @commands.call(@update, "remind", "in 20m Submit the report.\nInclude the chart.")
    @commands.call(@update, "queue", "reschedule 3 at 2026-10-03T09:00:00+08:00")

    assert_equal [[:remind, @update, { expression: "in 20m", text: "Submit the report.\nInclude the chart." }],
      [:queue_reschedule, @update, 3, "at 2026-10-03T09:00:00+08:00"]], @runtime.calls
    assert_equal ["Reminder scheduled.", "Request rescheduled."], @runtime.replies.map(&:last)
  end

  def test_incomplete_reminder_and_reschedule_commands_show_usage_without_admission
    ["", "in 20m", "at", "daily 09:00 Work"].each { |text| @commands.call(@update, "remind", text) }
    ["reschedule", "reschedule 0 now", "reschedule 1"].each { |text| @commands.call(@update, "queue", text) }

    assert_empty @runtime.calls
    @runtime.replies.each { |row| assert_includes row.last, "Use /" }
  end

  def test_group_task_controls_reach_the_runtime_for_request_ownership_checks
    update = @update.with(group: true)
    @commands.call(update, "steer", "Change the current work")
    @commands.call(update, "btw", "Read the conversation")

    assert_equal %i[submit side_question], @runtime.calls.map(&:first)
  end

  def test_access_management_requires_the_explicit_owner_in_both_chat_kinds
    [false, true].each do |group|
      @commands.call(@update.with(group: group), "access", "users add 9")
      assert_includes @runtime.replies.last.last, "Only the bot owner"
    end
    assert_empty @runtime.calls

    owner = @update.with(user_id: "owner")
    @commands.call(owner, "access", "users add 9")
    assert_equal [[:access_command, owner, "access", "users add 9"]], @runtime.calls
  end

  def test_observation_queries_are_public_to_admitted_members_but_changes_require_owner
    member = @update.with(group: true)
    ["", "status"].each do |argument|
      @commands.call(member, "observe", argument)
      assert_includes @runtime.replies.last.last, "Observe: off."
    end
    @commands.call(member, "observe", "on")
    assert_includes @runtime.replies.last.last, "Only the bot owner"
    assert_empty @runtime.calls

    owner = member.with(user_id: "owner")
    @commands.call(owner, "observe", "on")
    assert_equal [[:set_observe, owner, true]], @runtime.calls
    assert_includes @runtime.replies.last.last, "Shared scope: this group (-10)."

    @commands.call(member, "observe", "off")
    assert_includes @runtime.replies.last.last, "Only the bot owner"
    assert @runtime.observed?(member)
    assert_equal 1, @runtime.calls.length
  end

  def test_help_alias_is_available_to_group_members_and_names_both_busy_controls
    update = @update.with(group: true)
    @commands.call(update, "start", "")
    @commands.call(update, "help", "")

    assert_equal @runtime.replies[0].last, @runtime.replies[1].last
    assert_includes @runtime.replies[0].last, "/steer <text>"
    assert_includes @runtime.replies[0].last, "/btw <question>"
    assert_empty @runtime.calls
  end

  def test_unknown_commands_do_not_dispatch_runtime_or_object_methods
    %w[unknown submit initialize send].each do |name|
      @commands.call(@update, name, "text")
      assert_includes @runtime.replies.last.last, "Unknown command."
    end
    assert_empty @runtime.calls
  end
end
