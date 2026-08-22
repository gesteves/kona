# The `rails generate rspec:install` command made this file. Usually, each spec
# is in a `spec` directory, which RSpec adds to the `$LOAD_PATH`. The `.rspec`
# file contains `--require spec_helper`, which loads this file always. Thus no
# other file needs to require it.
#
# Because Ruby always loads this file, keep it small. If this file requires a
# large dependency, the start time of EVERY test run becomes longer, even for
# one file that does not need that dependency. Instead, make a different helper
# file that requires the more dependencies and does the more setup, then require
# that file from each spec file that needs it.
#
# Refer to https://rubydoc.info/gems/rspec-core/RSpec/Core/Configuration
RSpec.configure do |config|
  # The rspec-expectations configuration goes here. You can use a different
  # assertion library, such as wrong or the minitest assertions.
  config.expect_with :rspec do |expectations|
    # The default of this option is `true` in RSpec 4. It puts the text of each
    # helper method that `chain` defines into the `description` and the
    # `failure_message` of a custom matcher. For example:
    #     be_bigger_than(2).and_smaller_than(4).description
    #     # => "be bigger than 2 and smaller than 4"
    # Without it, the result is:
    #     # => "be bigger than 2"
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  # The rspec-mocks configuration goes here. To use a different test-double
  # library, such as bogus or mocha, change the `mock_with` option here.
  config.mock_with :rspec do |mocks|
    # This stops a mock or a stub of a method that does not exist on a real
    # object. Use it. Its default is `true` in RSpec 4.
    mocks.verify_partial_doubles = true
  end

  # The default of this option is `:apply_to_host_groups` in RSpec 4, and you
  # cannot set it off there. The option exists only for RSpec 3 compatibility.
  # It makes the metadata hash of each host group and each example take the
  # metadata of a shared context. Without it, RSpec adds the shared context to
  # each group with the same metadata.
  config.shared_context_metadata_behavior = :apply_to_host_groups

# The settings below give a good first experience with RSpec. You can change
# them.
=begin
  # This lets you run only the examples or the groups that you select. Give
  # them the `:focus` metadata. When no example has `:focus`, RSpec runs each
  # example. RSpec also gives other names for `it`, `describe`, and `context`
  # that include the `:focus` metadata: `fit`, `fdescribe`, and `fcontext`.
  config.filter_run_when_matching :focus

  # This lets RSpec keep some state between runs, for the `--only-failures` and
  # `--next-failure` options. Tell your source control system to ignore this
  # file.
  config.example_status_persistence_file_path = "spec/examples.txt"

  # This permits only the syntax that does not change other classes, which is
  # the correct syntax. For more data, refer to:
  # https://rspec.info/features/3-12/rspec-core/configuration/zero-monkey-patching-mode/
  config.disable_monkey_patching!

  # Most users run the full suite or one file. More output is useful for one
  # spec file.
  if config.files_to_run.one?
    # Use the documentation formatter for more output, but not if the
    # configuration already has a formatter, for example from a command-line
    # flag.
    config.default_formatter = "doc"
  end

  # Show the 10 slowest examples and example groups at the end of the run, to
  # find the specs that are very slow.
  config.profile_examples = 10

  # Run the specs in a random order, to find a dependency on the order. If you
  # find one and you must debug it, set the order: give the seed that RSpec
  # shows after each run.
  #     --seed 1234
  config.order = :random

  # The `--seed` option gives the seed for the random numbers in this process.
  # Thus you can use `--seed` with the value from a failed run, and a test
  # failure that a random value caused occurs again.
  Kernel.srand config.seed
=end
end
