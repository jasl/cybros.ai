require "test_helper"

class Nexus::SearchTermsTest < ActiveSupport::TestCase
  test "alternating languages normalize by bounded byte batches, not by language runs" do
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      queries << payload[:sql] if payload[:sql].include?("tsvector_to_array")
    end
    terms = search_terms(["中文 description\n" * 1_000])
    assert_includes terms, "中文"
    assert_includes terms, "descript"
    assert_operator queries.length, :<=, 5
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  test "the complete long source survives chunking and English inflections share terms" do
    source = "ordinary words " * 70_000 + " 搜索中文人工智能 running SEARCHES tailneedle"
    terms = search_terms([source])
    assert_includes terms, "tailneedl"
    assert_includes terms, "人工智能"
    assert_includes terms, "run"
    assert_includes terms, "search"
    assert_empty search_terms(["the and"])
    assert_equal search_terms(["runs searches"]), search_terms(["RUNNING search"])
  end

  private

    def search_terms(texts)
      ApplicationRecord.with_connection { |connection| Nexus::SearchTerms.for(texts, connection: connection) }
    end
end
