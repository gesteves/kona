# Sidekiq::ProcessSet, for the check below. The `require "sidekiq/web"` in the initializer also
# loads it, but no code here must depend on that.
require "sidekiq/api"

# Tells an admin page if a Sidekiq process runs and can do the queued jobs.
#
# ⚠️ A page reads this only while a record is at "Processing", and only to give the cause of a row
# that does not change. Such a page needs the worker for its main function: without this check, a
# record stays at "Processing" for all time and nothing says why. That is also why `worker` is not
# optional in .overmind.env. In production an empty set means that the worker machine is down.
module WorkerCheck
  private

  # @return [Boolean] True when a worker runs, and also when the check itself fails.
  def worker_running?
    Sidekiq::ProcessSet.new.size.positive?
  rescue StandardError => e
    Rails.logger.warn("#{self.class.name}: could not read Sidekiq's process set (#{e.class}: #{e.message})")
    true # Don't cry wolf if the check itself is what's broken.
  end
end
