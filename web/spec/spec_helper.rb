require 'middleman-core'
require 'middleman-core/load_paths'
# Most specs make a double with OpenStruct, and the helpers call the tag helpers of Padrino.
require 'ostruct'
require 'padrino-helpers'

# `.rspec` requires this file for each run, thus no spec file requires it.
Dir[File.expand_path('../support/**/*.rb', __FILE__)].sort.each { |file| require file }

require File.expand_path('../../lib/helpers', __FILE__)

RSpec.configure do |config|
  # Each example group gets each helper module, as a Middleman template does.
  each_kona_helper { |helper| config.include helper }

  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    # A stub of a method that the real object does not have fails.
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups

  # The order is random, to find an example that depends on another. To get the same order again,
  # give the seed of that run: `--seed 1234`.
  config.order = :random

  # The random numbers in an example come from the same seed.
  Kernel.srand config.seed

  # A helper keeps some values for the life of the process, by collection. An example starts with
  # none, thus it never reads a value that another example made.
  config.before { MemoizationHelpers.collection_store.clear }
end
