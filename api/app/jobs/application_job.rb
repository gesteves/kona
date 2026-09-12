# The base class of each background job. This app uses Sidekiq directly, and not ActiveJob, which
# stays off in application.rb. You can do each job more than one time, and each job takes plain
# strings as its arguments. Thus the shared `retry_for: 24.hours` is safe: Sidekiq waits between two
# attempts, then puts a job in the Dead set 24 hours after its first failure. It does not count the
# attempts.
class ApplicationJob
  include Sidekiq::Job

  # A failure that no retry can correct: an account that is not connected, a token that expired, a
  # post with no words. A service raises it, and the job goes to the Dead set at once and does not
  # use the 24-hour retry budget.
  class PermanentError < StandardError; end

  sidekiq_options retry_for: 24.hours

  sidekiq_retry_in do |_count, exception|
    case exception
    when PermanentError then :kill
    # The PDS said when it takes writes again. Thus the job waits that long, and it does not use
    # its 24-hour budget against a limit that is still there.
    when AtProto::RateLimitedError then exception.retry_after
    end
  end
end
