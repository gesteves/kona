# The base class of each background job. This app uses Sidekiq directly, and not ActiveJob, which
# stays off in application.rb. You can do each job more than one time, and each job takes plain
# strings as its arguments. Thus the shared `retry_for: 24.hours` is safe: Sidekiq waits between two
# attempts, then puts a job in the Dead set 24 hours after its first failure. It does not count the
# attempts.
class ApplicationJob
  include Sidekiq::Job

  sidekiq_options retry_for: 24.hours
end
