module PersonalGreeting
  NAME = "personal-greeting".freeze
  WORD = "Hello".freeze

  class Read
    NAME = "personal_greeting".freeze
    DESCRIPTION = "Read the person's configured greeting.".freeze
    SCHEMA = { "type" => "object", "properties" => {}, "additionalProperties" => false }.freeze
    EFFECT_PROFILE = { "kind" => "read_only", "destructive" => false, "effect_scope" => "closed",
      "idempotency" => "intrinsic", "reconciliation" => "none" }.freeze

    def initialize(env:, person:)
      @person = person
    end

    def call(_args) = Rho::Runner::Result.ok("#{WORD}, #{@person}.")
  end

  def self.register(api)
    person = api.configuration.fetch("person", "friend")
    tool = Class.new(Read)
    Read.constants(false).each { |name| tool.const_set(name, Read.const_get(name)) }
    tool.define_method(:initialize) { |env:| super(env: env, person: person) }
    api.register_tool(tool, serves: :agent)
  end
end
