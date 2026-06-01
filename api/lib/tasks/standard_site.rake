namespace :standard_site do
  desc "Reconciles all standard.site PDS records with the published Contentful corpus " \
       "(run once to seed; rerun to brute-force a full re-sync / recover dropped webhooks)"
  task backfill: :environment do
    StandardSite.new.backfill
    puts "standard.site backfill complete."
  end
end
