require 'spec_helper'
require 'tmpdir'
require_relative '../../../lib/utils/index_now'

RSpec.describe IndexNow do
  let(:redis) { instance_double(Redis) }
  let(:logged) { [] }
  let(:logger) { ->(line) { logged << line } }

  # The two entries that each example starts from.
  let(:sitemap) do
    {
      'https://example.com/' => '2026-09-05T18:57:14+00:00',
      'https://example.com/2026/09/01/a-post/' => '2026-09-01T12:00:00+00:00'
    }
  end

  before { allow(RedisConnection).to receive(:connection).and_return(redis) }

  # Writes a sitemap in the shape that source/sitemap.xml.erb renders.
  def sitemap_file(entries)
    urls = entries.map { |loc, lastmod| "<url><loc>#{loc}</loc><lastmod>#{lastmod}</lastmod></url>" }
    path = File.join(@tmp, 'sitemap.xml')
    File.write(path, %(<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">#{urls.join}</urlset>))
    path
  end

  # The previous submission that Redis holds. nil means that this app never submitted.
  def stored(entries)
    allow(redis).to receive(:get).with(described_class::REDIS_KEY).and_return(entries.nil? ? nil : JSON.dump(entries))
    allow(redis).to receive(:set)
  end

  def response(code)
    instance_double(HTTParty::Response, success?: code < 400, code: code, body: '')
  end

  def submit(entries = sitemap, **options)
    described_class.submit(
      sitemap_path: sitemap_file(entries),
      site_url: 'https://example.com',
      key: 'abc123',
      logger: logger,
      **options
    )
  end

  around do |example|
    Dir.mktmpdir { |dir| @tmp = dir; example.run }
  end

  context 'with no previous submission' do
    before { stored(nil) }

    it 'stores the sitemap and submits nothing' do
      expect(HTTParty).not_to receive(:post)
      expect(submit).to be_empty
      expect(redis).to have_received(:set).with(described_class::REDIS_KEY, JSON.dump(sitemap))
    end

    it 'submits every URL when the caller asks for all of them' do
      allow(HTTParty).to receive(:post).and_return(response(200))
      expect(submit(all: true)).to match_array(sitemap.keys)
    end
  end

  context 'with a previous submission' do
    it 'submits a URL that is new and a URL whose lastmod moved, and no other one' do
      stored('https://example.com/' => '2026-09-05T18:57:14+00:00', 'https://example.com/old/' => '2026-01-01T00:00:00+00:00')
      allow(HTTParty).to receive(:post).and_return(response(200))

      # The home page did not move, the post is new, and /old/ is gone from the sitemap.
      expect(submit).to eq([ 'https://example.com/2026/09/01/a-post/' ])
    end

    it 'sends the host, the key, the keyLocation, and the URLs' do
      stored({})
      allow(HTTParty).to receive(:post).and_return(response(200))
      submit

      expect(HTTParty).to have_received(:post).with(
        described_class::ENDPOINT,
        hash_including(
          headers: { 'Content-Type' => 'application/json; charset=utf-8' },
          body: JSON.dump(
            host: 'example.com',
            key: 'abc123',
            keyLocation: 'https://example.com/indexnow.txt',
            urlList: sitemap.keys
          )
        )
      )
    end

    # ⚠️ The lastmod of the sitemap holds the time, and not the date alone. Without it, a second
    # edit of the same day gives the same string and no URL goes to the engines.
    it 'submits a URL whose lastmod moved inside one day' do
      stored(sitemap)
      allow(HTTParty).to receive(:post).and_return(response(200))
      entries = sitemap.merge('https://example.com/' => '2026-09-05T21:30:00+00:00')

      expect(submit(entries)).to eq([ 'https://example.com/' ])
    end

    it 'submits nothing when no URL changed' do
      stored(sitemap)
      expect(HTTParty).not_to receive(:post)
      expect(submit).to be_empty
    end

    it 'stores the sitemap after a successful submission' do
      stored({})
      allow(HTTParty).to receive(:post).and_return(response(200))
      submit
      expect(redis).to have_received(:set).with(described_class::REDIS_KEY, JSON.dump(sitemap))
    end

    it 'prints the URLs and posts nothing on a dry run' do
      stored({})
      expect(HTTParty).not_to receive(:post)
      expect(submit(dry_run: true)).to match_array(sitemap.keys)
      expect(redis).not_to have_received(:set)
    end
  end

  context 'when the submission fails' do
    before { stored({}) }

    # 403 and 422 mean that the key or the host does not match the file at /indexnow.txt.
    [ 400, 403, 422 ].each do |code|
      it "raises on a #{code}, thus the CI run goes red" do
        allow(HTTParty).to receive(:post).and_return(response(code))
        expect { submit }.to raise_error(described_class::ConfigurationError, /#{code}/)
      end
    end

    # ⚠️ A stored sitemap after a failure would lose that change for all time: the next deploy
    # would find no difference.
    [ 429, 503 ].each do |code|
      it "stores nothing and does not raise on a #{code}" do
        allow(HTTParty).to receive(:post).and_return(response(code))
        expect(submit).to be_empty
        expect(redis).not_to have_received(:set)
        expect(logged.join).to include('::warning::')
      end
    end

    it 'stores nothing and does not raise on a network error' do
      allow(HTTParty).to receive(:post).and_raise(SocketError, 'getaddrinfo')
      expect(submit).to be_empty
      expect(redis).not_to have_received(:set)
    end
  end

  # A build that is not a production build writes localhost URLs, and IndexNow answers 422 for a URL
  # that is not on the host.
  context 'with a URL that is not on the host of the site' do
    it 'leaves it out and submits the others' do
      stored({})
      allow(HTTParty).to receive(:post).and_return(response(200))
      entries = sitemap.merge('http://localhost:4567/' => '2026-09-05T18:57:14+00:00')

      expect(submit(entries)).to match_array(sitemap.keys)
      expect(logged.join).to include('not on example.com')
    end

    it 'raises when no URL is on that host' do
      stored({})
      expect { submit({ 'http://localhost:4567/' => '2026-09-05T18:57:14+00:00' }) }
        .to raise_error(described_class::ConfigurationError, /is on the host/)
    end
  end

  it 'raises when the sitemap lists no URL' do
    stored(nil)
    expect { submit({}) }.to raise_error(described_class::ConfigurationError, /lists no URL/)
  end
end
