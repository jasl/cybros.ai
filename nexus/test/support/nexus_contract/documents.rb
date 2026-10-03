module Nexus
  module Contract
    class << self
      private

        # DURABLE MEMORY at its two doors, and A SKILL AS A ROW: the listing entry and the full
        # document as the one presenter renders them — `description` on both shapes, null on a plain
        # document, the skill row's line on a `skills/` one. The path carries the scope and rides
        # the body on every verb.
        def memory_documents
          plain, skill = memory_document_presenter_fixtures
          listing = memory_listing_fixture
          list_fixture = { "memory" => listing }

          {
            "scopes" => MemoryDocument::SCOPES,
            "max_documents_per_anchor" => MemoryDocument::MAX_DOCUMENTS_PER_ANCHOR,
            "name_max_length" => MemoryDocument::NAME_MAX_LENGTH,
            "content_bound" => Nexus::SizeBounds.fetch(:memory_document_bound),
            "skills_prefix" => Nexus::Skills::PREFIX,
            "skill_name_format" => Nexus::Skills::NAME_FORMAT.source,
            "skill_name_max_length" => Nexus::Skills::NAME_MAX_LENGTH,
            "skill_description_max_length" => Nexus::Skills::DESCRIPTION_MAX_LENGTH,
            "skill_anchors" => %w[workspace user],
            # THE THREE DOORS AND THE SCOPES EACH SERVES: the person's `user/` alone, the room's
            # `workspace/` alone, a conversation's all three — a path of another scope at a
            # one-scope door is `memory_scope_unavailable`.
            "door_scopes" => { "profile" => %w[user], "workspace" => %w[workspace],
                               "conversation" => %w[conversation workspace user] },
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
                            "expected_public_id" => nil, "expected_lock_version" => nil },
            },
            "valid_skill_write_request" => {
              "memory" => { "path" => skill.fetch("path"), "content" => skill.fetch("content"),
                            "description" => skill.fetch("description"),
                            "expected_public_id" => nil, "expected_lock_version" => nil },
            },
            "valid_update_request" => {
              "memory" => { "path" => plain.fetch("path"), "content" => "the revised plan",
                            "expected_public_id" => plain.fetch("public_id"),
                            "expected_lock_version" => plain.fetch("lock_version") },
            },
            "valid_delete_request" => {
              "memory" => { "path" => plain.fetch("path"), "expected_public_id" => plain.fetch("public_id"),
                            "expected_lock_version" => plain.fetch("lock_version") },
            },
            "valid_edit_request" => {
              "memory" => { "path" => plain.fetch("path"), "old_text" => "the plan", "new_text" => "the revised plan",
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
          document_type = Data.define(:path, :public_id, :lock_version, :bytesize, :description, :content, :memory_document_version)
          version = version_type.new(created_at: Time.utc(2026, 9, 15))
          plain = document_type.new(public_id: "01995000-0000-7000-8000-000000000001", lock_version: 2, path: "workspace/notes.md", bytesize: "the plan".bytesize,
            description: nil, content: "the plan", memory_document_version: version)
          skill = document_type.new(public_id: "01995000-0000-7000-8000-000000000002", lock_version: 0, path: "workspace/skills/commit-style",
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
            MemoryDocuments::Listing::Entry.new(public_id: "01995000-0000-7000-8000-000000000003", lock_version: 0, path: "user/skills/review-checklist", bytesize: 24,
              description: "How I review a change. Use before approving a pull request.", written_at: written_at),
            MemoryDocuments::Listing::Entry.new(public_id: "01995000-0000-7000-8000-000000000001", lock_version: 2, path: "workspace/notes.md", bytesize: 8,
              description: nil, written_at: written_at),
          ]
          AgentAPI::MemoryPresenter.listing(entries).map { |row| stringify_keys(row) }
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
