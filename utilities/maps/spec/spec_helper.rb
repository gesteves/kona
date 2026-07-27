RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    # Prevents mocking or stubbing a method that does not exist on a real object.
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups

  # Run specs in random order to surface order dependencies. Reproduce a
  # failure by passing the seed printed after each run: --seed 1234
  config.order = :random

  # Seed global randomization in this process using the `--seed` CLI option,
  # so randomness inside examples is reproducible too.
  Kernel.srand config.seed
end
