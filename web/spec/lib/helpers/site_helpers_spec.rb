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

  describe '#taxonomy_synonym_redirects' do
    def data
      OpenStruct.new(
        tags: [
          OpenStruct.new(tag: OpenStruct.new(path: '/tagged/triathlon/ironman-703/', synonyms: ['Half Ironman', '70.3'])),
          OpenStruct.new(tag: OpenStruct.new(path: '/tagged/running/', synonyms: [])),
          OpenStruct.new(tag: OpenStruct.new(path: '/tagged/triathlon/', synonyms: ['Multisport']))
        ],
        redirects: [OpenStruct.new(from: '/tagged/multisport')] # a configured redirect already claims this
      )
    end

    it 'maps synonym slugs to the canonical concept page' do
      expect(taxonomy_synonym_redirects).to include(
        { from: '/tagged/half-ironman', to: '/tagged/triathlon/ironman-703/', status: 301 },
        { from: '/tagged/70-3', to: '/tagged/triathlon/ironman-703/', status: 301 }
      )
    end

    it 'skips synonyms that collide with a configured redirect' do
      expect(taxonomy_synonym_redirects.map { |r| r[:from] }).not_to include('/tagged/multisport')
    end
  end

  describe '#collection_page_schema' do
    def content_summary(content) = "About #{content.title}."
    def canonical_url = 'https://example.com/tagged/triathlon/'

    it 'declares a CollectionPage about the topic, tied to the WebSite node' do
      schema = JSON.parse(collection_page_schema(OpenStruct.new(title: 'Triathlon')))
      expect(schema['@type']).to eq('CollectionPage')
      expect(schema['name']).to eq('Triathlon')
      expect(schema['description']).to eq('About Triathlon.')
      expect(schema['url']).to eq('https://example.com/tagged/triathlon/')
      expect(schema['about']).to eq('@type' => 'Thing', 'name' => 'Triathlon')
      expect(schema['isPartOf']).to eq('@id' => 'https://example.com/#website')
    end
  end

  describe '#alternate_feed_links' do
    def data = OpenStruct.new(site: OpenStruct.new(meta_title: 'My Site'))
    def page_content = @pc
    def feed_title = 'My Site'
    def taxonomy_index = { 'triathlon' => { name: 'Triathlon', path: '/tagged/triathlon/' } }
    def published_post?(content) = %w[Article Short].include?(content.entry_type) && !content.draft

    it 'advertises only the main site feed when the page has no content' do
      @pc = nil
      expect(alternate_feed_links).to eq([{ href: 'https://example.com/feed.xml', title: 'My Site' }])
    end

    it "adds the tag's own feed on a tag archive page" do
      @pc = OpenStruct.new(template: '/tag.html', tag_id: 'triathlon')
      expect(alternate_feed_links).to eq([
        { href: 'https://example.com/feed.xml', title: 'My Site' },
        { href: 'https://example.com/tagged/triathlon/feed.xml', title: 'My Site: Triathlon' }
      ])
    end

    it "adds every tag's feed on an article page" do
      @pc = OpenStruct.new(
        template: '/article.html', entry_type: 'Article', draft: false,
        contentful_metadata: OpenStruct.new(tags: [
          OpenStruct.new(name: 'Triathlon', path: '/tagged/triathlon/'),
          OpenStruct.new(name: 'Race Reports', path: '/tagged/race-reports/')
        ])
      )
      expect(alternate_feed_links).to eq([
        { href: 'https://example.com/feed.xml', title: 'My Site' },
        { href: 'https://example.com/tagged/triathlon/feed.xml', title: 'My Site: Triathlon' },
        { href: 'https://example.com/tagged/race-reports/feed.xml', title: 'My Site: Race Reports' }
      ])
    end

    it 'advertises only the main site feed on a non-tag, non-post page' do
      @pc = OpenStruct.new(template: '/page.html', entry_type: 'Page', draft: false)
      expect(alternate_feed_links).to eq([{ href: 'https://example.com/feed.xml', title: 'My Site' }])
    end
  end

  describe '#tag_breadcrumb_schema' do
    def full_url(path, *) = "https://example.com#{path}"
    def concept_chain(id)
      {
        'half-distance' => [
          { id: 'triathlon', name: 'Triathlon', path: '/tagged/triathlon/' },
          { id: 'half-distance', name: 'Half Distance', path: '/tagged/triathlon/half-distance/' }
        ]
      }.fetch(id, [])
    end

    it 'builds Home > Blog > the concept ancestor chain, ending at the concept' do
      schema = JSON.parse(tag_breadcrumb_schema(OpenStruct.new(tag_id: 'half-distance')))
      expect(schema['@type']).to eq('BreadcrumbList')
      expect(schema['itemListElement']).to eq([
        { '@type' => 'ListItem', 'position' => 1, 'name' => 'Home', 'item' => 'https://example.com/' },
        { '@type' => 'ListItem', 'position' => 2, 'name' => 'Blog', 'item' => 'https://example.com/blog' },
        { '@type' => 'ListItem', 'position' => 3, 'name' => 'Triathlon', 'item' => 'https://example.com/tagged/triathlon/' },
        { '@type' => 'ListItem', 'position' => 4, 'name' => 'Half Distance', 'item' => 'https://example.com/tagged/triathlon/half-distance/' }
      ])
    end

    it 'returns nil when the page has no concept' do
      expect(tag_breadcrumb_schema(OpenStruct.new(tag_id: nil))).to be_nil
      expect(tag_breadcrumb_schema(OpenStruct.new(tag_id: 'unknown'))).to be_nil
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
end
