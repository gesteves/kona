require 'spec_helper'
require 'ostruct'

# RSpec auto-includes the described module, so SiteHelpers' instance methods are callable directly.
RSpec.describe SiteHelpers do
  # Builds a site double shaped like `data.site`.
  def site(socials: [], logo: 'logo', author_name: 'Jane Doe', profile_picture: nil)
    OpenStruct.new(
      title: 'My Site',
      logo: logo,
      socials_collection: OpenStruct.new(items: socials.map { |t, d| OpenStruct.new(title: t, destination: d) }),
      author: OpenStruct.new(name: author_name, profile_picture: profile_picture)
    )
  end

  # Collaborators normally mixed in from other helper modules; defined here so the schema builders
  # can be exercised in isolation.
  def data = OpenStruct.new(site: @site || site)
  def full_url(path, *) = "https://example.com#{path}"
  def site_icon_url(w:) = "https://example.com/icon-#{w}.png"
  def cdn_image_url(url, params = {}) = "#{url}?w=#{params[:w]}"
  def sanitize(text, **) = text

  describe '#schema_entity_id' do
    it 'anchors an entity to a URL + fragment' do
      expect(schema_entity_id('organization')).to eq('https://example.com/#organization')
      expect(schema_entity_id('person', path: '/about')).to eq('https://example.com/about#person')
    end
  end

  describe '#author_same_as' do
    it 'returns social destinations, excluding the feed' do
      @site = site(socials: [['Feed', '/feed.xml'], ['Bluesky', 'https://bsky.app/x'], ['Mastodon', 'https://m.test/x']])
      expect(author_same_as).to eq(['https://bsky.app/x', 'https://m.test/x'])
    end

    it 'returns an empty array when no socials are configured' do
      @site = site(socials: [])
      expect(author_same_as).to eq([])
    end
  end

  describe '#site_schema_graph' do
    it 'builds a connected @graph of Organization, WebSite, and Person' do
      @site = site(
        socials: [['Feed', '/feed.xml'], ['Bluesky', 'https://bsky.app/x']],
        profile_picture: OpenStruct.new(url: '//img/me.jpg', description: 'A portrait.')
      )
      nodes = JSON.parse(site_schema_graph)['@graph'].each_with_object({}) { |n, h| h[n['@type']] = n }

      expect(nodes['Organization']).to include(
        '@id' => 'https://example.com/#organization',
        'sameAs' => ['https://bsky.app/x'],
        'logo' => 'https://example.com/icon-180.png'
      )
      expect(nodes['WebSite']).to include(
        '@id' => 'https://example.com/#website',
        'inLanguage' => 'en-US',
        'publisher' => { '@id' => 'https://example.com/#organization' }
      )
      expect(nodes['Person']).to include(
        '@id' => 'https://example.com/about#person',
        'name' => 'Jane Doe',
        'url' => 'https://example.com/about',
        'sameAs' => ['https://bsky.app/x']
      )
      expect(nodes['Person']['image']).to include('@type' => 'ImageObject', 'width' => 500, 'height' => 500, 'caption' => 'A portrait.')
    end

    it 'omits the logo, sameAs, and Person image when the data is absent' do
      @site = site(logo: nil, socials: [], profile_picture: nil)
      nodes = JSON.parse(site_schema_graph)['@graph'].each_with_object({}) { |n, h| h[n['@type']] = n }
      expect(nodes['Organization']).not_to have_key('logo')
      expect(nodes['Organization']).not_to have_key('sameAs')
      expect(nodes['Person']).not_to have_key('image')
      expect(nodes['Person']).not_to have_key('sameAs')
    end
  end

  describe '#profile_page_schema' do
    it 'points the ProfilePage mainEntity at the Person @id' do
      schema = JSON.parse(profile_page_schema)
      expect(schema['@type']).to eq('ProfilePage')
      expect(schema['mainEntity']).to eq('@id' => 'https://example.com/about#person')
    end
  end

  describe '#is_posthog_installed?' do
    around do |example|
      original = ENV.values_at('POSTHOG_KEY', 'POSTHOG_API_HOST')
      example.run
      ENV['POSTHOG_KEY'], ENV['POSTHOG_API_HOST'] = original
    end

    it 'is true only when both the key and the proxy origin are set' do
      ENV['POSTHOG_KEY'] = 'phc_test'
      ENV['POSTHOG_API_HOST'] = 'https://example.test'
      expect(is_posthog_installed?).to be true
    end

    it 'is false when either var is missing' do
      ENV['POSTHOG_KEY'] = 'phc_test'
      ENV['POSTHOG_API_HOST'] = nil
      expect(is_posthog_installed?).to be false

      ENV['POSTHOG_KEY'] = nil
      ENV['POSTHOG_API_HOST'] = 'https://example.test'
      expect(is_posthog_installed?).to be false
    end
  end
end
