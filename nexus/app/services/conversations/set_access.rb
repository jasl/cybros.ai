module Conversations
  # THE LATER CHANGE of the access carrier: a WHOLE
  # replacement of the default and the named entries,
  # idempotent by value with no receipt. The caller rule is full-control semantics (full
  # control includes changing
  # permissions): `full` on this row — the creator, the answerer, or a full
  # entry — with write standing on the workspace, which is `writable_by?`
  # and nothing new. Human kind grants no additional standing: a Human the
  # row lists at `read` reads, and cannot escalate itself.
  #
  # Under the row's own lock (the fork's, so a fork's copy and a change
  # serialize): absence for a tombstone; the principals resolved as the
  # create door resolves them; the levels judged by the records' own enum
  # (`invalid`, never a raise); an unchanged set is a plain acceptance;
  # else one `delete_all` + `insert_all!` (the fork's form) and ONE
  # `access_changed` item on the feed with the actor's KIND recorded.
  # No `context_revision` bump — assembly never reads the carrier — and
  # the archived bin accepts it: who may read the bin is not content.
  class SetAccess
    Command = Data.define(:conversation, :acting_user, :default, :entries)

    def self.call(command) = new(command).call

    def initialize(command)
      @command = command
    end

    def call
      conversation = @command.conversation
      return Outcome.refused(:not_authorized) unless conversation.writable_by?(@command.acting_user)

      conversation.with_lock do
        next Outcome.refused(:not_found) if conversation.tombstoned?

        principals = AccessPrincipals.resolve(
          account_id: conversation.account_id,
          derived_user_ids: [conversation.creating_user_id, conversation.answering_user_id],
          entries: @command.entries
        )
        next Outcome.refused(:principal_not_eligible) if principals.nil?

        conversation.access_default = @command.default
        entries = principals.map do |principal|
          ConversationAccessEntry.new(account: conversation.account, conversation_id: conversation.id,
            user: principal.user, level: principal.level)
        end
        invalid = [conversation, *entries].find(&:invalid?)
        if invalid
          # The instance stays clean for its caller: a dirty enum on a
          # locked row is not this door's residue.
          conversation.restore_attributes
          next Outcome.invalid(invalid)
        end
        next Outcome.accepted(conversation) if unchanged?(conversation, entries)

        replace(conversation, entries)
        narrate(conversation, entries)
        Outcome.accepted(conversation)
      end
    end

    private

      def unchanged?(conversation, entries)
        !conversation.access_default_changed? &&
          ConversationAccessEntry.where(conversation_id: conversation.id).pluck(:user_id, :level).to_h ==
            entries.to_h { |entry| [entry.user_id, entry.level] }
      end

      def replace(conversation, entries)
        conversation.save!
        ConversationAccessEntry.where(conversation_id: conversation.id).delete_all
        return if entries.empty?

        ConversationAccessEntry.insert_all!(entries.map do |entry|
          { account_id: entry.account_id, conversation_id: entry.conversation_id,
            user_id: entry.user_id, level: entry.level }
        end)
      end

      # The fact's kind is the actor's KIND, never "person" (the approver's
      # `origin_of` precedent): a transcript tells a delegate's change from
      # the person's. A fresh key: this is no replay contract.
      def narrate(conversation, entries)
        ConversationEvent::Append.call(host: conversation, items: [{
          type: "access_changed",
          payload: {
            "default" => conversation.access_default,
            "entries" => entries.map { |entry| { "user_public_id" => entry.user.public_id, "level" => entry.level } },
            "by" => @command.acting_user.public_id,
            "kind" => @command.acting_user.agent? ? "agent" : "human",
          },
        }])
      end
  end
end
