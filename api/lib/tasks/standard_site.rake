namespace :standard_site do
  desc "Reconciles all standard.site PDS records with the published Contentful corpus by " \
       "enqueuing a sync job per post (run once to seed; rerun to recover dropped webhooks). " \
       "Requires a running Sidekiq worker to drain the queue."
  task backfill: :environment do
    StandardSite.new.backfill
    puts "standard.site backfill enqueued (jobs drain on the Sidekiq worker)."
  end

  desc "Moves each standard_site:fingerprint:* key into the standard_site:fingerprints hash. " \
       "Run it one time after the deploy that makes that hash. DRY_RUN=1 only counts. It is " \
       "safe to run again."
  task migrate_fingerprints: :environment do
    # ⚠️ This task uses SCAN, and the app code must NOT. The rule against SCAN is for the request
    # path and the job path, because the Sidekiq queues share this keyspace. This runs one time, by
    # hand, with a cursor, against a dataset of a few MB. Do not copy it into a service.
    #
    # ⚠️ It moves the value and does not make it again. A fingerprint that this task loses makes
    # `do_sync_document` put the record again at the next publish, and that spends the PDS write
    # budget for no result.
    prefix = "standard_site:fingerprint:"
    dry_run = ENV["DRY_RUN"].present?
    moved = 0
    skipped = 0
    cursor = "0"

    loop do
      cursor, keys = $redis.scan(cursor, match: "#{prefix}*", count: 500)
      keys.each do |key|
        value = $redis.get(key)
        if value.blank?
          skipped += 1
          next
        end

        # The old key is "standard_site:fingerprint:<collection>:<rkey>", thus what is left after
        # the prefix is exactly the field that `fingerprint_field` makes.
        unless dry_run
          $redis.hset(StandardSite::FINGERPRINTS_KEY, key.delete_prefix(prefix), value)
          $redis.del(key)
        end
        moved += 1
      end
      break if cursor == "0"
    end

    total = $redis.hlen(StandardSite::FINGERPRINTS_KEY).to_i
    verb = dry_run ? "would move" : "moved"
    puts "standard.site fingerprints: #{verb} #{moved} key(s), skipped #{skipped} empty."
    puts "#{StandardSite::FINGERPRINTS_KEY} now holds #{total} field(s)."
  end
end
