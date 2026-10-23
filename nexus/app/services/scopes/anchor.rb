module Scopes
  class Anchor
    Result = Data.define(:collection, :scope, :name, :refusal) do
      def resolved? = refusal.nil?
      def documents = collection.memory_documents
      def lockable = collection.owner
      def conversation = collection&.conversation
      def workspace = collection&.workspace
      def user = collection&.user
      def speaker = collection&.speaker

      def write_refusal
        # Re-read parent lifecycle after the writer acquired its row lock;
        # a resolved pointer cannot outlive an owner removal while waiting.
        if collection.deleted? || conversation&.tombstoned? || workspace&.tombstoned? || (user && !user.active?)
          :memory_scope_unavailable
        elsif collection.archived?
          :memory_read_only
        end
      end
    end

    class << self
      def split(path)
        scope, name = path.to_s.split("/", 2)
        name.to_s.empty? ? [nil, nil] : [scope, name]
      end

      def refused(code)
        Result.new(collection: nil, scope: nil, name: nil, refusal: code)
      end
    end
  end
end
