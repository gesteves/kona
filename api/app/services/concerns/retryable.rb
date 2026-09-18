# Does a block again after a failure, with a wait that doubles each time, until the attempts or the
# deadline end. It raises the last error at the end, and the includer decides what that means.
#
# The wait is a flat back-off. It does not add a random part, because this app is one tenant, thus
# there is no group of clients to separate in time.
module Retryable
  # @param max [Integer] The maximum number of attempts after the first attempt.
  # @param base_delay [Numeric] The seconds to wait before the second attempt. Each wait is two
  #   times the last one.
  # @param deadline [Numeric] The maximum seconds for this call, and this includes the waits. An
  #   attempt does not occur if its wait would end after the deadline.
  # @param on [Class, Array<Class>] The errors that permit another attempt. Each other error
  #   raises at once.
  # @return [Object] The value from the block.
  # @raise [StandardError] The last error, after the attempts or the deadline end.
  def with_retries(max: 3, base_delay: 2, deadline: Float::INFINITY, on: StandardError)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    attempts = 0
    begin
      yield
    rescue *Array(on) => e
      attempts += 1
      delay = base_delay * (2**(attempts - 1))
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      raise e unless attempts <= max && (elapsed + delay) < deadline

      sleep(delay)
      retry
    end
  end
end
