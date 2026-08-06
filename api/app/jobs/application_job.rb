# Base class for all background jobs. This app uses native Sidekiq, not ActiveJob, which stays
# disabled in application.rb. Every job is idempotent and takes plain-string args, so the shared
# `retry_for: 24.hours` is safe: Sidekiq backs off normally, then Dead-sets a job once 24 hours
# have passed since its first failure, rather than capping by retry count.
class ApplicationJob
  include Sidekiq::Job

  sidekiq_options retry_for: 24.hours
end
