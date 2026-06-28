namespace :standard_site do
  desc "Reconciles all standard.site PDS records with the published Contentful corpus by " \
       "enqueuing a sync job per post (run once to seed; rerun to recover dropped webhooks). " \
       "Requires a running Sidekiq worker to drain the queue."
  task backfill: :environment do
    StandardSite.new.backfill
    puts "standard.site backfill enqueued (jobs drain on the Sidekiq worker)."
  end
end
