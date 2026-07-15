require 'spec_helper'

# lib/data/font_awesome.rb requires graphql/font_awesome, which fetches a Font Awesome
# access token and introspects the live GraphQL schema at load time (network + credentials,
# unavailable in CI). Register a stand-in module and mark that file as loaded so its require
# becomes a no-op — these specs stub the GraphQL client and Redis; they never hit the network.
graphql_client_path = File.expand_path('../../../lib/data/graphql/font_awesome.rb', __dir__)
unless $LOADED_FEATURES.include?(graphql_client_path)
  module FontAwesomeClient
    Client = nil
    module QUERIES
      Icons = nil
    end
  end
  $LOADED_FEATURES << graphql_client_path
end
require_relative '../../../lib/data/font_awesome'

# Minimal in-memory stand-in for the shared Redis build cache ($redis via
# RedisConnection.connection) — just the two commands FontAwesome uses.
class FontAwesomeSpecFakeRedis
  attr_reader :store

  def initialize(store = {})
    @store = store
  end

  def mget(*keys)
    keys.map { |k| @store[k] }
  end

  def set(key, value)
    @store[key] = value
  end
end

RSpec.describe FontAwesome do
  let(:version) { '7.3.0' }
  let(:cache) { FontAwesomeSpecFakeRedis.new }
  let(:client) { double('FontAwesomeClient::Client') }

  # The initializer builds the GraphQL client and fetches everything; allocate skips it so
  # the cache/API merge methods can be exercised against hand-built state.
  def importer
    described_class.allocate.tap do |instance|
      instance.instance_variable_set(:@client, client)
    end
  end

  # RedisConnection.connection memoizes into the global $redis; point it at the fake for
  # the duration of each example and restore whatever was there before.
  around do |example|
    original = $redis
    $redis = cache
    example.run
  ensure
    $redis = original
  end

  def key_for(family, style, icon_id)
    "font-awesome:icon:#{version}:#{family}:#{style}:#{icon_id}"
  end

  # A GraphQL response the shape fetch_from_api digs through: response.data.search is a
  # list of objects that serialize to hashes via to_h.
  def api_response(results)
    double('response', data: double('data', search: results.map { |r| double('result', to_h: r) }))
  end

  def api_result(id, svgs)
    {
      'id' => id,
      'svgs' => svgs.map do |(family, style, html)|
        { 'familyStyle' => { 'family' => family, 'style' => style }, 'html' => html }
      end
    }
  end

  describe '#cache_key_for' do
    it 'namespaces keys by version, family, style, and icon id' do
      expect(importer.send(:cache_key_for, '7.3.0', 'classic', 'solid', 'heart'))
        .to eq('font-awesome:icon:7.3.0:classic:solid:heart')
    end
  end

  describe '#get_icon_metadata' do
    it 'flattens the family → style → ids tree into cache keys mapped to [family, style, id]' do
      icons = {
        'classic' => { 'solid' => %w[heart check], 'brands' => %w[strava] },
        'sharp' => { 'light' => %w[heart] }
      }
      metadata = importer.send(:get_icon_metadata, icons, version)
      expect(metadata).to eq(
        key_for('classic', 'solid', 'heart') => %w[classic solid heart],
        key_for('classic', 'solid', 'check') => %w[classic solid check],
        key_for('classic', 'brands', 'strava') => %w[classic brands strava],
        key_for('sharp', 'light', 'heart') => %w[sharp light heart]
      )
    end
  end

  describe '#generate_icon_data' do
    let(:icons_yaml) { { 'classic' => { 'solid' => %w[heart check] } } }
    let(:metadata) { importer.send(:get_icon_metadata, icons_yaml, version) }

    it 'builds family → style → [{id:, svg:}] entirely from cache hits without touching the API' do
      instance = importer
      expect(instance).not_to receive(:fetch_from_api)

      svgs_from_cache = ['<svg>heart</svg>', '<svg>check</svg>'] # mget order matches metadata key order
      data = instance.send(:generate_icon_data, svgs_from_cache, metadata, version)

      expect(data).to eq(
        'classic' => {
          'solid' => [
            { id: 'heart', svg: '<svg>heart</svg>' },
            { id: 'check', svg: '<svg>check</svg>' }
          ]
        }
      )
    end

    it 'fetches only the cache misses from the API and merges them in position' do
      instance = importer
      allow(instance).to receive(:fetch_from_api)
        .with(version, 'classic', 'solid', 'check').and_return('<svg>check</svg>')

      data = instance.send(:generate_icon_data, ['<svg>heart</svg>', nil], metadata, version)

      expect(instance).to have_received(:fetch_from_api).once
      expect(data['classic']['solid']).to eq([
        { id: 'heart', svg: '<svg>heart</svg>' },
        { id: 'check', svg: '<svg>check</svg>' }
      ])
    end

    it 'treats an empty cached string as a miss and refetches' do
      instance = importer
      allow(instance).to receive(:fetch_from_api)
        .with(version, 'classic', 'solid', 'heart').and_return('<svg>heart</svg>')

      data = instance.send(:generate_icon_data, ['', '<svg>check</svg>'], metadata, version)

      expect(data['classic']['solid'].first).to eq(id: 'heart', svg: '<svg>heart</svg>')
    end

    it 'omits a family/style entirely when the API can supply none of its icons' do
      instance = importer
      allow(instance).to receive(:fetch_from_api).and_return(nil)

      data = instance.send(:generate_icon_data, [nil, nil], metadata, version)

      expect(data).to eq({})
    end
  end

  describe '#fetch_from_api' do
    it 'queries the API, picks the SVG matching the family and style, and writes it to the cache' do
      response = api_response([
        api_result('heart', [
          ['classic', 'regular', '<svg>regular heart</svg>'],
          ['classic', 'solid', '<svg>solid heart</svg>']
        ])
      ])
      expect(client).to receive(:query)
        .with(FontAwesomeClient::QUERIES::Icons, variables: { version: version, query: 'heart' })
        .and_return(response)

      svg = importer.send(:fetch_from_api, version, 'classic', 'solid', 'heart')

      expect(svg).to eq('<svg>solid heart</svg>')
      expect(cache.store).to eq(key_for('classic', 'solid', 'heart') => '<svg>solid heart</svg>')
    end

    it 'selects the exact icon id when the search returns several matches' do
      response = api_response([
        api_result('heart-pulse', [['classic', 'solid', '<svg>pulse</svg>']]),
        api_result('heart', [['classic', 'solid', '<svg>heart</svg>']])
      ])
      allow(client).to receive(:query).and_return(response)

      expect(importer.send(:fetch_from_api, version, 'classic', 'solid', 'heart')).to eq('<svg>heart</svg>')
    end

    it 'returns nil and writes nothing when the search comes back empty' do
      allow(client).to receive(:query).and_return(api_response([]))

      expect(importer.send(:fetch_from_api, version, 'classic', 'solid', 'no-such-icon')).to be_nil
      expect(cache.store).to be_empty
    end

    it 'returns nil and writes nothing when the icon has no SVG in the requested family/style' do
      response = api_response([api_result('heart', [['sharp', 'light', '<svg>sharp heart</svg>']])])
      allow(client).to receive(:query).and_return(response)

      expect(importer.send(:fetch_from_api, version, 'classic', 'solid', 'heart')).to be_nil
      expect(cache.store).to be_empty
    end

    it 'returns nil when the matching icon carries no svgs key at all' do
      response = api_response([{ 'id' => 'heart' }])
      allow(client).to receive(:query).and_return(response)

      expect(importer.send(:fetch_from_api, version, 'classic', 'solid', 'heart')).to be_nil
    end

    it 'returns nil when the fuzzy search has results but none matches the exact id' do
      response = api_response([api_result('heart-pulse', [['classic', 'solid', '<svg>pulse</svg>']])])
      allow(client).to receive(:query).and_return(response)

      expect(importer.send(:fetch_from_api, version, 'classic', 'solid', 'heart')).to be_nil
      expect(cache.store).to be_empty
    end

    # response.data comes back nil when the API returns top-level errors (expired token,
    # rate limiting, etc.). This used to raise and abort the whole import; now it retries.
    def errored_response
      double('response', data: nil, errors: double('errors', messages: { 'data' => ['boom'] }))
    end

    it 'retries when the API returns no data, then skips the icon without raising' do
      instance = importer
      allow(instance).to receive(:sleep) # don't actually wait between retries
      expect(client).to receive(:query).exactly(FontAwesome::MAX_API_RETRIES).times.and_return(errored_response)

      expect(instance.send(:fetch_from_api, version, 'classic', 'solid', 'heart')).to be_nil
      expect(cache.store).to be_empty
    end

    it 'recovers on a retry when a transient failure is followed by a good response' do
      instance = importer
      allow(instance).to receive(:sleep)
      good = api_response([api_result('heart', [['classic', 'solid', '<svg>heart</svg>']])])
      expect(client).to receive(:query).and_return(errored_response, good)

      expect(instance.send(:fetch_from_api, version, 'classic', 'solid', 'heart')).to eq('<svg>heart</svg>')
      expect(cache.store).to eq(key_for('classic', 'solid', 'heart') => '<svg>heart</svg>')
    end
  end

  describe '#get_icons' do
    let(:yaml_data) do
      { 'version' => version, 'icons' => { 'classic' => { 'solid' => %w[heart] } } }
    end

    before do
      allow(YAML).to receive(:load_file).with('data/font_awesome.yml').and_return(yaml_data)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('FONT_AWESOME_VERSION').and_return(nil)
    end

    it 'reads the allowlist, checks the cache under the YAML version, and merges the result' do
      cache.set(key_for('classic', 'solid', 'heart'), '<svg>heart</svg>')

      expect(importer.send(:get_icons)).to eq(
        'classic' => { 'solid' => [{ id: 'heart', svg: '<svg>heart</svg>' }] }
      )
    end

    it 'lets FONT_AWESOME_VERSION override the YAML version, changing the cache keys and query' do
      allow(ENV).to receive(:[]).with('FONT_AWESOME_VERSION').and_return('8.0.0')
      cache.set('font-awesome:icon:8.0.0:classic:solid:heart', '<svg>v8 heart</svg>')

      expect(importer.send(:get_icons)).to eq(
        'classic' => { 'solid' => [{ id: 'heart', svg: '<svg>v8 heart</svg>' }] }
      )
    end
  end

  describe '#save_data' do
    it 'serializes the icon tree to data/icons.json in the shape the site data expects' do
      instance = importer
      instance.instance_variable_set(:@icons, 'classic' => { 'solid' => [{ id: 'heart', svg: '<svg/>' }] })

      io = StringIO.new
      expect(File).to receive(:open).with('data/icons.json', 'w').and_yield(io)
      instance.save_data

      expect(JSON.parse(io.string)).to eq(
        'classic' => { 'solid' => [{ 'id' => 'heart', 'svg' => '<svg/>' }] }
      )
    end
  end
end
