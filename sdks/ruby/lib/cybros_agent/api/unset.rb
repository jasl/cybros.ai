module CybrosAgent
  module Api
    # The keyword-omission sentinel: a keyword left at this
    # default sends no field at all, while a caller's explicit nil travels as
    # JSON null for the server to judge. Private machinery — the public
    # contract is the keyword's absence, never this object.
    UNSET = Object.new
    UNSET.define_singleton_method(:inspect) { "CybrosAgent::Api::UNSET" }
    UNSET.freeze
    private_constant :UNSET

    # THE ONE BODY BUILDER: a request body from keywords — a keyword left at UNSET sends no
    # field, an explicit nil travels as JSON null for the server to judge. Every context
    # spells its body through here, so omission has one meaning across the gem.
    module Fields
      private

        def fields(**given)
          given.reject { |_, value| UNSET.equal?(value) }.transform_keys(&:to_s)
        end

        # A keyword whose WIRE form is derived (a nested body, an id list):
        # the transform of a given value, or UNSET carried through untouched
        # for `fields` to drop.
        def field(value)
          UNSET.equal?(value) ? UNSET : yield(value)
        end

        # A query string from keywords: a nil keyword sends no parameter,
        # and no parameters at all send no query.
        def query(**given)
          params = given.compact.transform_keys(&:to_s)
          params.empty? ? nil : params
        end
    end
  end
end
