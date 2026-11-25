require 'spec_helper'
require 'tmpdir'
require File.expand_path('../../../lib/data/api_imports', __dir__)

# The icon import stops the build on purpose: each page needs the icons. These examples test the
# retries, which cover a cold start of the api, and the raise after them.
RSpec.describe ApiImports do
  around do |example|
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        FileUtils.mkdir_p('data')
        File.write('data/font_awesome.yml', { 'icons' => { 'classic' => { 'light' => %w[eye bars] } } }.to_yaml)
        example.run
      end
    end
  end

  before do
    stub_env('KONA_API_URL' => 'https://api.example/', 'API_TOKEN' => 'token')
    allow(described_class).to receive(:sleep)
    allow(described_class).to receive(:warn)
  end

  def response(body, code: 200)
    instance_double(HTTParty::Response, success?: code == 200, code: code, body: body.to_json)
  end

  def icons_body(*ids)
    { 'classic' => { 'light' => ids.map { |id| { 'id' => id, 'svg' => "<svg>#{id}</svg>" } } } }
  end

  describe '.icons' do
    it 'posts the icons in groups and writes them in the order of the list' do
      stub_const('ApiImports::ICON_BATCH_SIZE', 1)
      allow(HTTParty).to receive(:post).and_return(response(icons_body('eye')), response(icons_body('bars')))

      described_class.icons

      expect(HTTParty).to have_received(:post).with('https://api.example/api/icons', hash_including(timeout: 30)).twice
      written = JSON.parse(File.read('data/icons.json'))
      expect(written.dig('classic', 'light').map { |icon| icon['id'] }).to eq(%w[eye bars])
    end

    # ⚠️ The api machines stop by themselves, thus the first request of a build can fail while the
    # origin starts.
    it 'tries a failed group again after a wait' do
      allow(HTTParty).to receive(:post).and_return(response({}, code: 503), response(icons_body('eye', 'bars')))

      described_class.icons

      expect(described_class).to have_received(:sleep).with(ApiImports::ICON_RETRY_DELAYS.first)
      expect(File).to exist('data/icons.json')
    end

    it 'raises after the last attempt, and writes no file' do
      allow(HTTParty).to receive(:post).and_return(response({}, code: 503))

      expect { described_class.icons }.to raise_error(/HTTP 503/)
      expect(HTTParty).to have_received(:post).exactly(ApiImports::ICON_MAX_RETRIES + 1).times
      expect(File).not_to exist('data/icons.json')
    end

    it 'raises when the api gives no icons, and writes no file' do
      allow(HTTParty).to receive(:post).and_return(response({}))

      expect { described_class.icons }.to raise_error(/returned no icons/)
      expect(File).not_to exist('data/icons.json')
    end

    it 'raises with no api URL, and makes no request' do
      stub_env('KONA_API_URL' => nil)
      allow(HTTParty).to receive(:post)

      expect { described_class.icons }.to raise_error(/KONA_API_URL is not set/)
      expect(HTTParty).not_to have_received(:post)
    end
  end
end
