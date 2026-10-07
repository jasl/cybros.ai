module CybrosAgent
  module Api
    module OperationProjections
      include Parsing

      SHAPES = {
        OperationContext => { tools: :json_array, model_defaults: :json_object, environment: :optional_json_object },
        OperationRefusal => { code: :string, message: :string },
        OperationEvent => {
          type: :string,
          position: :integer,
          key: :string,
          request: :optional_json_object,
          receipt: :optional_json_object,
          outcome: :json,
          refusal: [:optional_shape, OperationRefusal],
        },
        TaskOperations => {
          context: [:shape, OperationContext],
          trace: [:shapes, OperationEvent],
          position: :integer,
          next_after: :optional_integer,
        },
        OperationRead => {
          observation: lambda do |hash|
            raise MalformedResponse, "expected observation" unless hash.key?("observation")

            optional_shape(OperationEvent, hash, "observation")
          end,
          position: :integer,
        },
      }.freeze
    end
  end
end
