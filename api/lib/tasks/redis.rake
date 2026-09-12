namespace :redis do
  # The durable records of this app: the Redis of `kona-redis` is their only copy. Each other key
  # in that keyspace is a cache with a TTL, a lock, or a Sidekiq queue, and each one of those comes
  # back by itself.
  #
  # ⚠️ These tasks name each key from a constant, and they use no SCAN. Refer to
  # `standard_site:migrate_fingerprints` for the one place that a SCAN is permitted, and why.
  #
  # ⚠️ **The file holds each secret exactly as Redis holds it, that is, ENCRYPTED with
  # `secret_key_base`.** Thus an import needs the SAME `RAILS_MASTER_KEY`. With a different key,
  # `EncryptedCredentials.decrypt` gives nil, each card says "not connected", and nothing raises.
  # ⚠️ **The file is still sensitive. Keep it off the repository and out of a shared drive.**

  # The Redis hashes to export, as [label, key] pairs.
  # ⚠️ These are locals and not methods, on purpose. A `def` inside a namespace defines a private
  # method on Object, and a generic name there can collide with another rake file.
  durable_hashes = lambda do
    [
      [ "spam quarantine",      SpamQuarantine::REDIS_KEY ],
      [ "course-map tracks",    TrackLibrary::REDIS_KEY ],
      [ "bluesky",              BlueskyCredentials::REDIS_KEY ],
      [ "mastodon",             MastodonCredentials::REDIS_KEY ],
      [ "threads",              ThreadsCredentials::REDIS_KEY ],
      [ "trainerroad",          TrainerRoadCredentials::REDIS_KEY ],
      [ "whoop (store)",        WhoopCredentials::REDIS_KEY ],
      [ "standard.site prints", StandardSite::FINGERPRINTS_KEY ]
    ]
  end

  # The plain string keys to export.
  #
  # ⚠️ The Whoop refresh token has no expiry and no other copy, and it is the one key that the
  # comment of `redis/fly.toml` named first. The access token is absent here, on purpose: a refresh
  # makes it again.
  durable_strings = lambda do
    keys = [
      [ "location",           Location::LOCATION_CACHE_KEY ],
      [ "standard.site DID",  StandardSite::DID_CACHE_KEY ]
    ]

    client_id = ENV["WHOOP_CLIENT_ID"].presence
    if client_id
      keys << [ "whoop refresh token", "whoop:#{client_id}:refresh_token" ]
      keys << [ "whoop refresh error", "whoop:#{client_id}:refresh_error" ]
      keys << [ "whoop account email", "whoop:#{client_id}:account_email" ]
    end
    keys
  end

  # The path of the dump file.
  dump_path = lambda do
    ENV["FILE"].presence || Rails.root.join("tmp", "redis-durable.json").to_s
  end

  desc "Writes each durable Redis record to a JSON file. FILE=<path> selects the file; the " \
       "default is tmp/redis-durable.json. ⚠️ The file holds each secret, encrypted."
  task export: :environment do
    payload = { "version" => 1, "exported_at" => Time.now.utc.iso8601, "hashes" => {}, "strings" => {} }

    durable_hashes.call.each do |label, key|
      entries = $redis.hgetall(key)
      next if entries.blank?
      payload["hashes"][key] = entries
      puts format("  %-22s %s (%d field(s))", label, key, entries.size)
    end

    durable_strings.call.each do |label, key|
      value = $redis.get(key)
      next if value.nil?
      payload["strings"][key] = value
      puts format("  %-22s %s", label, key)
    end

    path = dump_path.call
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(payload))
    # The file holds credentials. Only the owner of the file can read it.
    File.chmod(0o600, path)

    fields = payload["hashes"].values.sum(&:size)
    puts "Wrote #{payload['hashes'].size} hash(es) (#{fields} field(s)) and " \
         "#{payload['strings'].size} string(s) to #{path}."
    puts "⚠️ It holds each secret, encrypted with secret_key_base. Keep it off the repository."
  end

  desc "Reads a redis:export file back into Redis. FILE=<path> selects the file. It refuses a " \
       "key that already holds data; FORCE=1 replaces one."
  task import: :environment do
    path = dump_path.call
    abort("No file at #{path}. Give FILE=<path>.") unless File.exist?(path)

    payload = JSON.parse(File.read(path))
    abort("#{path} is not a redis:export file.") unless payload.is_a?(Hash) && payload["version"] == 1

    force = ENV["FORCE"].present?
    written = 0
    refused = 0

    payload["hashes"].to_h.each do |key, entries|
      next if entries.blank?

      if $redis.exists?(key) && !force
        puts "  refused #{key}: it already holds data. Use FORCE=1 to replace it."
        refused += 1
        next
      end

      $redis.del(key) if force
      # ⚠️ One HSET for each field, and not a MULTI. The set is small, and a partial import that a
      # person can see is better than one transaction that fails as a whole with no report.
      entries.each { |field, value| $redis.hset(key, field, value) }
      written += 1
      puts "  wrote #{key} (#{entries.size} field(s))"
    end

    payload["strings"].to_h.each do |key, value|
      next if value.nil?

      if $redis.exists?(key) && !force
        puts "  refused #{key}: it already holds data. Use FORCE=1 to replace it."
        refused += 1
        next
      end

      # ⚠️ SET with no TTL. Each key here is durable, thus a TTL would lose it later.
      $redis.set(key, value)
      written += 1
      puts "  wrote #{key}"
    end

    puts "Imported #{written} key(s) from #{path}. Refused #{refused}."
    puts "Open /connected-apps and check that each card names its account." if written.positive?
  end
end
