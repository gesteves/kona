require "rails_helper"
require "rake"

# `rake redis:export` is the only backup of the durable records: this Redis is their only copy.
# Thus a key that the export misses goes away at the next loss of the volume, and nothing reports
# it.
RSpec.describe "redis:export and redis:import" do
  # ⚠️ WhoopCredentials holds no hash: the Whoop tokens are in the keys of Whoop#durable_keys.
  # Each other class with encrypted credentials keeps one hash at its REDIS_KEY.
  credential_classes = Dir[Rails.root.join("app/**/*.rb")]
    .select { |path| File.read(path).include?("include EncryptedCredentials") }
    .map { |path| File.read(path)[/^class (\w+)/, 1].constantize }
    .reject { |klass| klass == WhoopCredentials }

  let(:file) { Rails.root.join("tmp", "redis-rake-spec-#{SecureRandom.hex(4)}.json").to_s }

  let(:durable_hashes) do
    [ SpamQuarantine::REDIS_KEY, TrackLibrary::REDIS_KEY, StandardSite::FINGERPRINTS_KEY,
      *credential_classes.map { |klass| klass::REDIS_KEY } ]
  end

  let(:durable_strings) do
    [ Location::LOCATION_CACHE_KEY, StandardSite::DID_CACHE_KEY, Strava::SUBSCRIPTION_KEY,
      *Whoop.new.durable_keys.map(&:last) ]
  end

  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("redis:export")
  end

  before { stub_env("FILE" => file, "FORCE" => nil, "WHOOP_CLIENT_ID" => "client-1") }
  after { FileUtils.rm_f(file) }

  # Runs one task, with its output kept out of the spec log.
  def run_task(name)
    Rake::Task[name].reenable
    expect { Rake::Task[name].invoke }.to output.to_stdout
  end

  def seed
    durable_hashes.each { |key| $redis.hset(key, "field", "value of #{key}") }
    durable_strings.each { |key| $redis.set(key, "value of #{key}") }
  end

  it "finds each class with encrypted credentials, thus this spec covers a new one" do
    expect(credential_classes).to include(BlueskyCredentials, MastodonCredentials, StravaCredentials,
                                          ThreadsCredentials, TrainerRoadCredentials)
  end

  it "writes each durable record, and puts each one back into an empty Redis" do
    seed
    run_task("redis:export")
    $redis.flushdb

    run_task("redis:import")

    durable_hashes.each { |key| expect($redis.hgetall(key)).to eq("field" => "value of #{key}") }
    durable_strings.each { |key| expect($redis.get(key)).to eq("value of #{key}") }
  end

  # ⚠️ The import sets no TTL: a TTL would lose a durable key later.
  it "puts back each string with no TTL" do
    seed
    run_task("redis:export")
    $redis.flushdb

    run_task("redis:import")

    durable_strings.each { |key| expect($redis.ttl(key)).to eq(-1) }
  end

  it "writes a file that only its owner can read" do
    seed
    run_task("redis:export")

    expect(File.stat(file).mode & 0o777).to eq(0o600)
  end

  it "refuses a key that already holds data, and replaces it with FORCE=1" do
    seed
    run_task("redis:export")
    $redis.hset(SpamQuarantine::REDIS_KEY, "field", "newer")

    run_task("redis:import")
    expect($redis.hget(SpamQuarantine::REDIS_KEY, "field")).to eq("newer")

    stub_env("FORCE" => "1")
    run_task("redis:import")
    expect($redis.hget(SpamQuarantine::REDIS_KEY, "field")).to eq("value of #{SpamQuarantine::REDIS_KEY}")
  end

  it "refuses a file that is not an export, and writes nothing" do
    File.write(file, { "version" => 2, "hashes" => { SpamQuarantine::REDIS_KEY => { "a" => "b" } } }.to_json)

    Rake::Task["redis:import"].reenable
    expect { Rake::Task["redis:import"].invoke }
      .to raise_error(SystemExit).and output(/is not a redis:export file/).to_stderr
    expect($redis.exists?(SpamQuarantine::REDIS_KEY)).to be(false)
  end
end
