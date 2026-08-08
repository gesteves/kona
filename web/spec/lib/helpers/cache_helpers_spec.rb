require 'spec_helper'
require_relative '../../../lib/utils/redis_connection'

RSpec.describe CacheHelpers do
  # $redis is a global memo, so each example starts from a clean slate.
  around do |example|
    previous = $redis
    $redis = nil
    example.run
    $redis = previous
  end

  describe '#redis' do
    it 'opens the shared connection with the build-time timeouts' do
      client = double('redis')
      expect(Redis).to receive(:new).with(
        hash_including(connect_timeout: 5, read_timeout: 3, write_timeout: 3, reconnect_attempts: [0.1, 0.5, 1.0])
      ).once.and_return(client)

      expect(redis).to be(client)
    end

    # The blurhash cache reaches for this once per asset; a fresh connection per call would open
    # one socket per image against a metered Upstash instance.
    it 'memoizes the connection across calls' do
      allow(Redis).to receive(:new).once.and_return(double('redis'))

      expect(redis).to be(redis)
      expect(Redis).to have_received(:new).once
    end

    it 'reads the URL from REDIS_URL' do
      original = ENV['REDIS_URL']
      ENV['REDIS_URL'] = 'rediss://cache.example:6380'
      expect(Redis).to receive(:new).with(hash_including(url: 'rediss://cache.example:6380')).and_return(double('redis'))

      redis
    ensure
      ENV['REDIS_URL'] = original
    end

    it 'falls back to a local Redis when REDIS_URL is unset' do
      original = ENV['REDIS_URL']
      ENV.delete('REDIS_URL')
      expect(Redis).to receive(:new).with(hash_including(url: 'redis://localhost:6379')).and_return(double('redis'))

      redis
    ensure
      ENV['REDIS_URL'] = original
    end
  end
end
