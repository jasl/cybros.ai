require "test_helper"

class ContentBodies::FragmentLookupTest < ActiveSupport::TestCase
  test "sealing an unchanged request reuses locked fragments without writing their payloads" do
    entries = [
      { "role" => "user", "text" => "repeat this request" },
      { "role" => "assistant", "text" => "unchanged answer" },
    ]
    first = seal(entries)
    original_ids = first.content_body_entries.pluck(:content_fragment_id)
    inserted_payloads = []
    insert_all = ContentFragment.method(:insert_all)

    second = ContentFragment.stub(:insert_all, lambda { |rows, **options|
      inserted_payloads.concat(rows.map { |row| row.fetch(:payload) })
      insert_all.call(rows, **options)
    }) { seal(entries) }

    assert_equal original_ids, second.content_body_entries.pluck(:content_fragment_id)
    assert_equal entries, second.content_body_entries.map { |entry| entry.content_fragment.payload }
    assert_empty inserted_payloads,
      "an existing request must not resend its payloads to a conflict-tolerant INSERT"
  end

  test "sealing an extended request inserts only its new message payload" do
    prefix = [
      { "role" => "user", "text" => "retained prefix" },
      { "role" => "assistant", "text" => "retained answer" },
    ]
    first = seal(prefix)
    original_ids = first.content_body_entries.pluck(:content_fragment_id)
    added = { "role" => "user", "text" => "one new question" }
    entries = prefix + [added, prefix.first, added]
    inserted_payloads = []
    insert_all = ContentFragment.method(:insert_all)

    second = ContentFragment.stub(:insert_all, lambda { |rows, **options|
      inserted_payloads.concat(rows.map { |row| row.fetch(:payload) })
      insert_all.call(rows, **options)
    }) { seal(entries) }

    assert_equal [added], inserted_payloads,
      "only unique missing payloads may cross the database write boundary"
    assert_equal original_ids, second.content_body_entries.pluck(:content_fragment_id).first(2)
    assert_equal entries, second.content_body_entries.map { |entry| entry.content_fragment.payload }
  end

  test "sealing a repeated request resolves fragment identities without reading stored payloads" do
    entries = Array.new(64) do |index|
      { "role" => "user", "text" => "message #{index}: #{"context " * 512}" }
    end
    first = seal(entries)
    original_ids = first.content_body_entries.pluck(:content_fragment_id)
    entries << { "role" => "user", "text" => "the next question" }

    connection = ApplicationRecord.lease_connection
    select_all = connection.method(:select_all)
    payload_bytes = 0
    connection.clear_query_cache
    second = connection.stub(:select_all, lambda { |*arguments, **options|
      result = select_all.call(*arguments, **options)
      if result.columns.include?("digest") && result.columns.include?("payload")
        position = result.columns.index("payload")
        payload_bytes += result.rows.sum { |row| row.fetch(position).bytesize }
      end
      result
    }) { seal(entries) }

    assert_equal original_ids, second.content_body_entries.pluck(:content_fragment_id).first(64)
    assert_equal entries, second.content_body_entries.map { |entry| entry.content_fragment.payload }
    assert_equal 0, payload_bytes,
      "the writer already owns the payloads; identity resolution must not fetch them again"
  end

  private

    def seal(entries)
      owner = OneShot.create!(account: accounts(:cybros), workspace: workspaces(:shared),
        creating_user: users(:member), workload: "text_generation")
      ContentBodies::Replace.call(owner: owner, role: "input", entries: entries, seal: true).body
    end
end
