require_relative "test_helper"

class TelegramRateLimitTest < Minitest::Test
  def setup
    @now = 100.0
    @rate = Rho::IngressTelegram::RateLimit.new(clock: -> { @now })
  end

  def test_private_progress_and_messages_share_the_chat_budget
    assert @rate.ready?(chat_id: 1, group: false, progress: true)
    @rate.sent(chat_id: 1, group: false, progress: true)
    refute @rate.ready?(chat_id: 1, group: false)
    assert_in_delta 101.0, @rate.next_at(chat_id: "1", group: false, progress: true)
    @now += 1
    assert @rate.ready?(chat_id: 1, group: false, progress: true)
  end

  def test_group_progress_coalesces_but_final_can_take_the_next_ordinary_slot
    @rate.sent(chat_id: -2, group: true, progress: true)
    assert_in_delta 104.0, @rate.next_at(chat_id: -2, group: true, progress: true)
    assert_in_delta 103.0, @rate.next_at(chat_id: -2, group: true)
    # No topic identifier enters the limiter: another topic has the same budget.
    refute @rate.ready?(chat_id: "-2", group: true)
  end

  def test_different_chats_still_share_the_bot_budget
    @rate.sent(chat_id: 1, group: false)
    assert_in_delta 100.0 + 1.0 / 30, @rate.next_at(chat_id: 2, group: false)
    @now += 1.0 / 30
    assert @rate.ready?(chat_id: 2, group: false)
    refute @rate.ready?(chat_id: 1, group: false)
  end

  def test_flood_wait_blocks_all_priorities_and_cannot_be_shortened
    @rate.retry_after(7)
    @now += 1
    @rate.retry_after(1)
    assert_in_delta 107.0, @rate.next_at(chat_id: 1, group: false)
    assert_in_delta 107.0, @rate.next_at(chat_id: -2, group: true, progress: true)
    refute @rate.ready?(chat_id: 3, group: false)
    @now = 107.0
    assert @rate.ready?(chat_id: 3, group: false)
    assert_raises(ArgumentError) { @rate.retry_after(-1) }
  end
end
