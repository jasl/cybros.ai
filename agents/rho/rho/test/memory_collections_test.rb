require "test_helper"
require "rho/memory_collections"

class MemoryCollectionsTest < Minitest::Test
  Conversation = Struct.new(:selected) do
    def memory(speaker_public_id: nil) = self
    def bindings = { "bindings" => [selected] }
  end
  Profile = Struct.new(:public_id, :memory_collections, :agents) do
    def fetch = self
    def member = self
  end
  Agents = Struct.new(:rows, :collections) do
    def list = rows
    def memory_collections(name:) = collections.fetch(name)
  end
  Agent = Data.define(:name, :public_id)
  OwnerCollections = Struct.new(:writes, :after_create) do
    def create(**fields)
      writes << fields
      after_create.call
    end
  end

  def binding(owner: "agent", subject: "alice", state: "unallocated", access: "read_write")
    { "name" => "speaker", "source" => { "scope" => "speaker" }, "scope" => "speaker", "access" => access,
      "owner_public_id" => owner, "speaker_public_id" => subject, "collection_public_id" => nil, "state" => state }
  end

  def test_explicit_initialization_selects_the_own_or_named_agent_and_the_exact_subject
    %w[agent named].product(%w[alice bob]).each do |owner, subject|
      conversation = Conversation.new(binding(owner: owner, subject: subject))
      writes = []
      collections = OwnerCollections.new(writes, -> {
        conversation.selected.merge!("collection_public_id" => "#{owner}/#{subject}", "state" => "active")
      })
      profile = Profile.new("agent", owner == "agent" ? collections : nil,
        Agents.new([Agent.new(name: "helper", public_id: "named")], { "helper" => collections }))
      selected = Rho::MemoryCollections.target(conversation: conversation, path: "speaker/notes.md",
        speaker_public_id: subject, client: Struct.new(:profile).new(profile))
      assert_equal "#{owner}/#{subject}", selected.fetch("collection_public_id")
      assert_equal [{ default: true, speaker_public_id: subject }], writes
    end
  end

  def test_unavailable_or_read_only_collections_are_never_created_or_restored
    [%w[deleted read_write], %w[archived read], %w[active read]].each do |state, access|
      conversation = Conversation.new(binding(state: state, access: access))
      client = Object.new
      assert_raises(Rho::Error) do
        Rho::MemoryCollections.target(conversation: conversation, path: "speaker/notes.md", client: client)
      end
    end
  end

  def test_a_rebound_or_changed_subject_during_initialization_is_not_adopted
    %w[source speaker_public_id].each do |changed|
      conversation = Conversation.new(binding)
      collections = OwnerCollections.new([], -> {
        conversation.selected.merge!("state" => "active", "collection_public_id" => "replacement")
        conversation.selected[changed] = changed == "source" ? { "collection_public_id" => "replacement" } : "bob"
      })
      profile = Profile.new("agent", collections, nil)
      error = assert_raises(Rho::Error) do
        Rho::MemoryCollections.target(conversation: conversation, path: "speaker/notes.md", client: Struct.new(:profile).new(profile))
      end
      assert_includes error.message, "binding changed"
    end
  end
end
