namespace :blurhash do
  desc "Enqueues a blurhash placeholder job for every published Contentful asset (run once after " \
       "the deploy to seed the placeholders; rerun to recover dropped webhooks). Each job skips an " \
       "asset that already has an entry, so re-running is cheap. Set DRY_RUN=1 to report the count " \
       "without enqueuing. Requires a running Sidekiq worker to drain the queue."
  task backfill: :environment do
    result = BlurhashPlaceholder.new.backfill(dry_run: ENV["DRY_RUN"].present?)
    if result == :skipped
      puts "blurhash backfill skipped — the Contentful asset fetch failed."
    elsif ENV["DRY_RUN"].present?
      puts "blurhash backfill dry run: #{result} asset(s) would be enqueued."
    else
      puts "blurhash backfill enqueued for #{result} asset(s) (jobs drain on the Sidekiq worker)."
    end
  end
end
