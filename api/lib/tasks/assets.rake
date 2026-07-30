namespace :assets do
  desc "Enqueues an R2 mirror job for every published Contentful asset (run once to seed the " \
       "bucket before the web site is pointed at IMAGE_HOST; rerun to recover dropped webhooks). " \
       "Each job skips an asset already in the bucket, so re-running is cheap. Set DRY_RUN=1 to " \
       "report the count without enqueuing. Requires a running Sidekiq worker to drain the queue."
  task backfill: :environment do
    result = AssetMirror.new.backfill(dry_run: ENV["DRY_RUN"].present?)
    if result == :skipped
      puts "assets backfill skipped — R2 is not configured (see the R2_* vars in .env.example)."
    elsif ENV["DRY_RUN"].present?
      puts "assets backfill dry run: #{result} asset(s) would be enqueued."
    else
      puts "assets backfill enqueued for #{result} asset(s) (jobs drain on the Sidekiq worker)."
    end
  end
end
