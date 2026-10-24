$LOAD_PATH.unshift File.expand_path("..", __dir__)
require_relative "../support/product_world"
require_relative "../../support/test_world"
E2E.world_class = E2E::ProductWorld
