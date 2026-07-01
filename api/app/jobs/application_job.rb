# Base class for all background jobs. This app uses native Sidekiq (`Sidekiq::Job`, not
# ActiveJob — ActiveJob stays disabled in application.rb), so this is a plain superclass that
# mixes in `Sidekiq::Job` and carries the shared options every job relies on. Every operation
# is idempotent and takes plain-string args, so the `retry: 5` here is safe for all jobs;
# exhausted retries land in the Dead set.
class ApplicationJob
  include Sidekiq::Job

  sidekiq_options retry: 5
end
