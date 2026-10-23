module Nexus
  module Contract
    class << self
      private

        # The document presenter is shared by collection and conversation doors.
        def memory_documents
          plain, skill = memory_document_presenter_fixtures
          listing = memory_listing_fixture
          list_fixture = { "memory" => listing }

          {
            # Human-owned `user/` stays separate from the answering Agent's `agent/`
            # and its `(Agent, Speaker)` pair. Ordinary execution defaults omit `user/`.
            "scopes" => MemoryContext::SCOPES.map(&:to_s),
            "default_scopes" => MemoryContext::DEFAULT_SCOPES.map(&:to_s),
            "max_documents_per_collection" => MemoryDocument::MAX_DOCUMENTS_PER_COLLECTION,
            "name_max_length" => MemoryDocument::NAME_MAX_LENGTH,
            "content_bound" => Nexus::SizeBounds.fetch(:memory_document_bound),
            "skills_prefix" => Nexus::Skills::PREFIX,
            "skill_name_format" => Nexus::Skills::NAME_FORMAT.source,
            "skill_name_max_length" => Nexus::Skills::NAME_MAX_LENGTH,
            "skill_description_max_length" => Nexus::Skills::DESCRIPTION_MAX_LENGTH,
            "skill_anchors" => %w[agent workspace speaker user],
            "door_paths" => { "collection" => "relative", "conversation" => "binding/name" },
            "speaker_owner_fields" => %w[owner_public_id speaker_public_id],
            "binding_name_format" => MemoryContext::NAME.source,
            "max_bindings" => MemoryContext::MAX_BINDINGS,
            "binding_access" => %w[read read_write],
            "model_reserved_prefix_refusal" => "memory_reserved_prefix",
            # The `skill` load's one error word: a tool RESULT the model reads (`is_error`), never
            # an HTTP code — the kernel's for a name in neither rung, and the same envelope shape an
            # announcing runner answers for a name it no longer holds.
            "skill_load_unknown_refusal" => "skill_unknown",
            "list_envelope" => list_fixture.keys,
            "singular_envelope" => %w[memory],
            "basic_projection" => listing.first.keys,
            "full_projection_adds" => plain.keys - listing.first.keys,
            "error_codes" => MEMORY_ERROR_STATUSES.keys,
            "error_statuses" => MEMORY_ERROR_STATUSES,
            "valid_fixture" => { "memory" => plain },
            "valid_skill_fixture" => { "memory" => skill },
            "valid_list_fixture" => list_fixture,
            "valid_write_request" => {
              "memory" => { "path" => plain.fetch("path"), "content" => plain.fetch("content"),
                            "expected_collection_public_id" => plain.fetch("collection_public_id"),
                            "expected_public_id" => nil, "expected_lock_version" => nil },
            },
            "valid_skill_write_request" => {
              "memory" => { "path" => skill.fetch("path"), "content" => skill.fetch("content"),
                            "description" => skill.fetch("description"),
                            "expected_collection_public_id" => plain.fetch("collection_public_id"),
                            "expected_public_id" => nil, "expected_lock_version" => nil },
            },
            "valid_update_request" => {
              "memory" => { "path" => plain.fetch("path"), "content" => "the revised plan",
                            "expected_collection_public_id" => plain.fetch("collection_public_id"),
                            "expected_public_id" => plain.fetch("public_id"),
                            "expected_lock_version" => plain.fetch("lock_version") },
            },
            "valid_delete_request" => {
              "memory" => { "path" => plain.fetch("path"), "expected_collection_public_id" => plain.fetch("collection_public_id"),
                            "expected_public_id" => plain.fetch("public_id"),
                            "expected_lock_version" => plain.fetch("lock_version") },
            },
            "valid_edit_request" => {
              "memory" => { "path" => plain.fetch("path"), "old_text" => "the plan", "new_text" => "the revised plan",
                            "expected_collection_public_id" => plain.fetch("collection_public_id"),
                            "expected_public_id" => plain.fetch("public_id"), "expected_lock_version" => plain.fetch("lock_version") },
            },
            "valid_grep_request" => { "memory" => { "pattern" => "plan", "path" => "workspace/" } },
            "valid_grep_fixture" => stringify_keys(AgentAPI::MemoryPresenter.search(MemoryDocuments::Search::Result.new(
              matches: [MemoryDocuments::Search::Match.new(path: plain.fetch("path"), line_number: 1, text: "the plan")],
              truncated: false, refusal: nil))),
            "valid_delete_fixture" => { "status" => 204, "body" => nil },
            "valid_error_fixture" =>
              api_error_fixture("skill_description_required", MEMORY_ERROR_STATUSES.fetch("skill_description_required")),
            "unknown_error_fixture" => unknown_api_error_fixture,
            "unknown_field_behavior" => "ignore",
          }
        end

        # A plain document and a skill row, rendered by the presenter over
        # doubles shaped like the rows: the version row's age is the
        # content's, the description is the row's.
        def memory_document_presenter_fixtures
          version_type = Data.define(:created_at)
          document_type = Data.define(:memory_collection, :path, :public_id, :lock_version, :bytesize, :description, :content, :memory_document_version)
          collection = Data.define(:public_id).new(public_id: "01995000-0000-7000-8000-000000000010")
          version = version_type.new(created_at: Time.utc(2026, 9, 15))
          plain = document_type.new(memory_collection: collection, public_id: "01995000-0000-7000-8000-000000000001", lock_version: 2, path: "workspace/notes.md", bytesize: "the plan".bytesize,
            description: nil, content: "the plan", memory_document_version: version)
          skill = document_type.new(memory_collection: collection, public_id: "01995000-0000-7000-8000-000000000002", lock_version: 0, path: "workspace/skills/commit-style",
            bytesize: "# Commits\n\nOne line, imperative.\n".bytesize,
            description: "How this team writes commit messages. Use before every commit.",
            content: "# Commits\n\nOne line, imperative.\n", memory_document_version: version)
          [
            stringify_keys(AgentAPI::MemoryPresenter.full(plain)),
            stringify_keys(AgentAPI::MemoryPresenter.full(skill)),
          ]
        end

        def memory_listing_fixture
          written_at = Time.utc(2026, 9, 15)
          entries = [
            MemoryDocuments::Listing::Entry.new(collection_public_id: "01995000-0000-7000-8000-000000000010", public_id: "01995000-0000-7000-8000-000000000003", lock_version: 0, path: "user/skills/review-checklist", bytesize: 24,
              description: "How I review a change. Use before approving a pull request.", written_at: written_at),
            MemoryDocuments::Listing::Entry.new(collection_public_id: "01995000-0000-7000-8000-000000000010", public_id: "01995000-0000-7000-8000-000000000001", lock_version: 2, path: "workspace/notes.md", bytesize: 8,
              description: nil, written_at: written_at),
          ]
          AgentAPI::MemoryPresenter.listing(entries).map { |row| stringify_keys(row) }
        end

        def memory_collections
          owner = Data.define(:public_id).new(public_id: "01900000-0000-7000-8000-000000000001")
          row = Data.define(:public_id, :name, :description, :natural_scope, :owner, :speaker,
            :is_default, :archived_at, :lock_version, :created_at, :updated_at).new(
            public_id: "01995000-0000-7000-8000-000000000010", name: "Team notes", description: "Shared references",
            natural_scope: :workspace, owner: owner, speaker: nil, is_default: false, archived_at: nil,
            lock_version: 2, created_at: Time.utc(2026, 10, 23), updated_at: Time.utc(2026, 10, 23))
          access = Object.new
          def access.writable?(_collection) = true
          def access.manageable?(_collection) = true
          full = stringify_keys(AgentAPI::MemoryCollectionPresenter.full(row, access: access))
          plain, skill = memory_document_presenter_fixtures.map { |item| item.merge("path" => item.fetch("path").split("/", 2).last) }
          {
            "projection" => full.keys,
            "valid_fixture" => { "memory_collection" => full },
            "valid_default_fixture" => { "memory_collection" => stringify_keys(AgentAPI::MemoryCollectionPresenter.full(
              row.with(name: nil, description: nil, is_default: true), access: access)) },
            "valid_list_fixture" => { "memory_collections" => [full], "pagination" => { "next_after" => nil } },
            "valid_create_request" => { "memory_collection" => { "name" => full.fetch("name"), "description" => full.fetch("description") } },
            "valid_update_request" => { "memory_collection" => { "name" => "Revised notes", "lock_version" => full.fetch("lock_version") } },
            "valid_lifecycle_request" => { "memory_collection" => { "lock_version" => full.fetch("lock_version") } },
            "valid_document_fixture" => { "memory" => plain },
            "valid_skill_fixture" => { "memory" => skill },
            "valid_documents_fixture" => { "memory" => [plain.except("content")] },
            "valid_write_request" => { "memory" => { "path" => plain.fetch("path"), "content" => plain.fetch("content"),
              "expected_public_id" => nil, "expected_lock_version" => nil } },
            "valid_delete_fixture" => { "status" => 204, "body" => nil },
          }
        end

        # THE THREE SLOTS: one entity kind on memory's anchor shape, addressed by slot in the URL at
        # two doors — the workspace's `character`, the acting user's own `system_prompt` (an agent)
        # or `persona` (a Human). The vocabularies are CLOSED: a stranger slot or role is refused by
        # name. Macros ride the content unrendered; the assembler substitutes them at compile.
        def prompt_documents
          full = prompt_document_presenter_fixture
          listing = full.except("content")
          list_fixture = { "prompt_documents" => [listing] }

          {
            "slots" => PromptDocument::SLOTS,
            # The placed slots: `summarizer` is a slot of the door and never of the template —
            # content-only, read by the kernel-mode compaction summarizer.
            "assembly_slots" => PromptDocument::ASSEMBLY_SLOTS,
            "roles" => PromptDocument::ROLES,
            "default_role" => PromptDocument::DEFAULT_ROLE,
            "anchors" => %w[workspace user],
            "slot_anchors" => PromptDocument::SLOT_ANCHORS.transform_values(&:to_s),
            "macros" => Nexus::PromptMacros::REGISTRY,
            "content_bound" => Nexus::SizeBounds.fetch(PromptDocument::CONTENT_BOUND),
            "list_envelope" => list_fixture.keys,
            "singular_envelope" => %w[prompt_document],
            "basic_projection" => listing.keys,
            "full_projection_adds" => full.keys - listing.keys,
            "error_codes" => PROMPT_DOCUMENT_ERROR_STATUSES.keys,
            "error_statuses" => PROMPT_DOCUMENT_ERROR_STATUSES,
            "valid_fixture" => { "prompt_document" => full },
            "valid_list_fixture" => list_fixture,
            "valid_put_request" => {
              "prompt_document" => { "content" => full.fetch("content"), "role" => full.fetch("role") },
            },
            "valid_delete_fixture" => { "status" => 204, "body" => nil },
            "valid_error_fixture" => api_error_fixture("prompt_slot_unavailable",
              PROMPT_DOCUMENT_ERROR_STATUSES.fetch("prompt_slot_unavailable")),
            "unknown_slot_fixture" => { "prompt_document" => full.merge("slot" => "mood") },
            "unknown_role_fixture" => { "prompt_document" => full.merge("role" => "tool") },
            "unknown_error_fixture" => unknown_api_error_fixture,
            "unknown_field_behavior" => "ignore",
          }
        end

        def prompt_document_presenter_fixture
          document = PromptDocument.new(
            slot: "character", role: "system", version: 2,
            content: "You are in {{workspace}} with {{user}}.",
            bytesize: "You are in {{workspace}} with {{user}}.".bytesize,
            updated_at: Time.utc(2026, 9, 8)
          )
          stringify_keys(AgentAPI::PromptDocumentPresenter.full(document))
        end
    end
  end
end
