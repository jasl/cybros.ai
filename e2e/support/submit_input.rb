require "json"
require "cybros_agent"

# A deliberately short-lived application: submit one input, print its durable
# receipt, and exit without fetching results or starting an executor.
request = JSON.parse($stdin.read)
client = CybrosAgent::Client.new(base_url: request.fetch("base_url"), credential: request.fetch("credential"))
conversation = client.workspace(request.fetch("workspace_public_id")).conversation(request.fetch("conversation_public_id"))
accepted = conversation.inputs.create(**request.fetch("input").transform_keys(&:to_sym))
puts JSON.generate("input_public_id" => accepted.public_id)
