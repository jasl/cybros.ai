module E2E
  module Evals
    # THE RAILS FAMILY'S APP IMAGES: the one tag each carries on ghcr (read 2026-09-13), both
    # linux/amd64 only. Its own file so the loader (a task's `image`) and the docker hooks read one
    # map without requiring each other.
    module DockerBases
      IMAGES = {
        "writebook" => "ghcr.io/evilmartians/lemans-writebook:v1.2.1",
        "fizzy" => "ghcr.io/evilmartians/lemans-fizzy:8112b3d",
      }.freeze

      module_function

      def base_for(profile) = IMAGES.fetch(profile.to_s) { raise ArgumentError, "no Agents-on-Rails image for profile #{profile.inspect}: #{IMAGES.keys.join(", ")}" }
    end
  end
end
