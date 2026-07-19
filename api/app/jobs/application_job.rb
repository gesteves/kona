# Base class for all background jobs. This app uses native Sidekiq (`Sidekiq::Job`, not
# ActiveJob — ActiveJob stays disabled in application.rb), so this is a plain superclass that
# mixes in `Sidekiq::Job` and carries the shared options every job relies on. Every operation
# is idempotent and takes plain-string args, so the shared `retry_for: 24.hours` here is safe
# for all jobs: Sidekiq retries with its normal exponential backoff but stops — moving the job
# to the Dead set — once 24 hours have elapsed since the first failure, rather than capping by a
# fixed retry count.
class ApplicationJob
  include Sidekiq::Job

  sidekiq_options retry_for: 24.hours
end
