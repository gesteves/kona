# The values of ENV for one example.
module EnvHelpers
  # Gives ENV the given values for the example. Each other key reads the true environment.
  #
  # ⚠️ Use this, and do not write to ENV: a write stays for the examples that come after it, and
  # the true environment, which rake loads from .env, then decides the result.
  # ⚠️ Use this and not `allow(ENV)` directly: a second `and_call_original` in one example goes
  # in front of each value that an earlier stub gave.
  # @param values [Hash{String => String, nil}] Each variable name and its value. nil is a
  #   variable with no value.
  def stub_env(values)
    unless @env_stubbed
      allow(ENV).to receive(:[]).and_call_original
      @env_stubbed = true
    end
    values.each { |key, value| allow(ENV).to receive(:[]).with(key.to_s).and_return(value) }
  end
end

RSpec.configure do |config|
  config.include EnvHelpers
end
