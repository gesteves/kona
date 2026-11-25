require 'spec_helper'

# spec_helper.rb includes each helper module, thus an example calls the instance methods of
# SchemaHelpers directly.
RSpec.describe SchemaHelpers do
  include_context 'default helper stubs'

  # Makes a site double with the shape of `data.site`.
  def site(socials: [], logo: 'logo', author_name: 'Jane Doe', profile_picture: nil)
    OpenStruct.new(
      title: 'My Site',
      logo: logo,
      socials_collection: OpenStruct.new(items: socials.map { |t, d| OpenStruct.new(title: t, destination: d) }),
      author: OpenStruct.new(name: author_name, profile_picture: profile_picture)
    )
  end

  # These replace `data` of Middleman and two methods of ImageHelpers. Thus the test runs the
  # schema builders alone.
  def data = OpenStruct.new(site: @site || site)
  def site_icon_url(w:) = "https://example.com/icon-#{w}.png"
  def cdn_image_url(url, params = {}) = "#{url}?w=#{params[:w]}"

  describe '#schema_entity_id' do
    it 'anchors an entity to a URL + fragment' do
      expect(schema_entity_id('organization')).to eq('https://example.com/#organization')
      expect(schema_entity_id('person', path: '/about')).to eq('https://example.com/about#person')
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

    it 'omits mainEntity when the page lists no entries' do
      schema = JSON.parse(collection_page_schema(OpenStruct.new(title: 'Triathlon')))
      expect(schema).not_to have_key('mainEntity')
    end

    it 'enumerates the listed entries as a mainEntity ItemList' do
      content = OpenStruct.new(title: 'Triathlon', items: [
        OpenStruct.new(title: 'First Race', path: '/2025/01/01/first/'),
        OpenStruct.new(title: 'Second Race', path: '/2025/02/02/second/')
      ])
      list = JSON.parse(collection_page_schema(content))['mainEntity']
      expect(list['@type']).to eq('ItemList')
      expect(list['numberOfItems']).to eq(2)
      expect(list['itemListElement']).to eq([
        { '@type' => 'ListItem', 'position' => 1, 'url' => 'https://example.com/2025/01/01/first/', 'name' => 'First Race' },
        { '@type' => 'ListItem', 'position' => 2, 'url' => 'https://example.com/2025/02/02/second/', 'name' => 'Second Race' }
      ])
    end
  end

  describe '#tag_breadcrumb_schema' do
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
        { '@type' => 'ListItem', 'position' => 2, 'name' => 'Blog', 'item' => 'https://example.com/blog/' },
        { '@type' => 'ListItem', 'position' => 3, 'name' => 'Triathlon', 'item' => 'https://example.com/tagged/triathlon/' },
        { '@type' => 'ListItem', 'position' => 4, 'name' => 'Half Distance', 'item' => 'https://example.com/tagged/triathlon/half-distance/' }
      ])
    end

    it 'returns nil when the page has no concept' do
      expect(tag_breadcrumb_schema(OpenStruct.new(tag_id: nil))).to be_nil
      expect(tag_breadcrumb_schema(OpenStruct.new(tag_id: 'unknown'))).to be_nil
    end

    # ⚠️ /blog with no slash at the end is a 301 (auto-trailing-slash). Thus a crumb without it
    # points at a redirect while each other URL on the page is canonical.
    it 'gives the Blog crumb the slash at the end, thus it is not a redirect' do
      schema = JSON.parse(tag_breadcrumb_schema(OpenStruct.new(tag_id: 'half-distance')))
      blog = schema['itemListElement'].find { |i| i['name'] == 'Blog' }
      expect(blog['item']).to end_with('/blog/')
    end
  end

  describe '#blog_schema' do
    def canonical_url = 'https://example.com/blog'
    def published_datetime(item) = DateTime.parse(item.published_at)

    before { @site = OpenStruct.new(meta_title: 'My Site', meta_description: 'A blog about triathlon.') }

    it 'declares a Blog tied to the sitewide nodes, listing this page\'s entries as blogPost refs' do
      content = OpenStruct.new(title: 'Blog', items: [
        OpenStruct.new(title: 'First', path: '/2025/01/01/first/', published_at: '2025-01-01T00:00:00Z'),
        OpenStruct.new(title: 'Second', path: '/2025/02/02/second/', published_at: '2025-02-02T00:00:00Z')
      ])
      schema = JSON.parse(blog_schema(content))
      expect(schema['@type']).to eq('Blog')
      expect(schema['name']).to eq('Blog')
      expect(schema['description']).to eq('A blog about triathlon.')
      expect(schema['url']).to eq('https://example.com/blog')
      expect(schema['isPartOf']).to eq('@id' => 'https://example.com/#website')
      expect(schema['publisher']).to eq('@id' => 'https://example.com/#organization')
      expect(schema['blogPost']).to eq([
        { '@type' => 'BlogPosting', 'headline' => 'First', 'url' => 'https://example.com/2025/01/01/first/',
          'datePublished' => '2025-01-01T00:00:00+00:00', 'author' => { '@id' => 'https://example.com/about#person' } },
        { '@type' => 'BlogPosting', 'headline' => 'Second', 'url' => 'https://example.com/2025/02/02/second/',
          'datePublished' => '2025-02-02T00:00:00+00:00', 'author' => { '@id' => 'https://example.com/about#person' } }
      ])
    end

    it 'yields an empty blogPost list when the page lists no entries' do
      expect(JSON.parse(blog_schema(OpenStruct.new(title: 'Blog')))['blogPost']).to eq([])
    end
  end

  describe '#author_knows_about' do
    def data = OpenStruct.new(tags: @tags)

    it 'returns the top-level sports disciplines, sorted, excluding nested and non-sports concepts' do
      @tags = [
        OpenStruct.new(tag: OpenStruct.new(name: 'Triathlon', scheme: 'sports', parent_id: nil)),
        OpenStruct.new(tag: OpenStruct.new(name: 'Half Distance', scheme: 'sports', parent_id: 'triathlon')),
        OpenStruct.new(tag: OpenStruct.new(name: 'Running', scheme: 'sports', parent_id: nil)),
        OpenStruct.new(tag: OpenStruct.new(name: 'Race Reports', scheme: 'topics', parent_id: nil))
      ]
      expect(author_knows_about).to eq([ 'Running', 'Triathlon' ])
    end

    it 'returns an empty array when there are no tags' do
      @tags = nil
      expect(author_knows_about).to eq([])
    end
  end

  describe '#author_same_as' do
    it 'returns social destinations, excluding the feed' do
      @site = site(socials: [ [ 'Feed', '/feed.xml' ], [ 'Bluesky', 'https://bsky.app/x' ], [ 'Mastodon', 'https://m.test/x' ] ])
      expect(author_same_as).to eq([ 'https://bsky.app/x', 'https://m.test/x' ])
    end

    it 'returns an empty array when no socials are configured' do
      @site = site(socials: [])
      expect(author_same_as).to eq([])
    end
  end

  describe '#site_schema_graph' do
    it 'builds a connected @graph of Organization, WebSite, and Person' do
      @site = site(
        socials: [ [ 'Feed', '/feed.xml' ], [ 'Bluesky', 'https://bsky.app/x' ] ],
        profile_picture: OpenStruct.new(url: '//img/me.jpg', description: 'A portrait.')
      )
      nodes = JSON.parse(site_schema_graph)['@graph'].each_with_object({}) { |n, h| h[n['@type']] = n }

      expect(nodes['Organization']).to include(
        '@id' => 'https://example.com/#organization',
        'sameAs' => [ 'https://bsky.app/x' ],
        'logo' => 'https://example.com/icon-180.png'
      )
      expect(nodes['WebSite']).to include(
        '@id' => 'https://example.com/#website',
        'inLanguage' => 'en-US',
        'publisher' => { '@id' => 'https://example.com/#organization' }
      )
      # ⚠️ `url` has the slash at the end and `@id` does not, and that is on purpose. `url` is a
      # navigable claim, and activate :directory_indexes puts that page at /about/, thus a URL with
      # no slash names a 301. `@id` is an opaque identifier that each `author` reference points at,
      # and a change to it would orphan every one of them.
      expect(nodes['Person']).to include(
        '@id' => 'https://example.com/about#person',
        'name' => 'Jane Doe',
        'url' => 'https://example.com/about/',
        'sameAs' => [ 'https://bsky.app/x' ]
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

# The schema of one entry. These examples need the article doubles, and not the site double of
# the group above.
RSpec.describe SchemaHelpers, 'for one entry' do
  include_context 'default helper stubs'
  include_context 'article doubles'

  # The canonical URL of the article under test. The schema groups below share it.
  def canonical_url = 'https://example.com/2024/01/01/post/'

  describe '#article_schema' do
    # These replace the methods of other helper modules, and the `current_page` of Middleman. Thus
    # the test runs the schema builder alone.
    def content_summary(content) = content.summary
    def schema_entity_id(fragment, path: '/') = "https://example.com#{path == '/' ? '/' : "#{path}/"}##{fragment}"
    def cdn_image_url(url, params = {}) = "#{url}?w=#{params[:w]}&h=#{params[:h]}"
    def open_graph_card_url(path, version) = "https://example.com#{path.chomp('/')}/og.png?v=#{version}"
    def current_page = OpenStruct.new(url: '/2024/01/01/post/')

    def schema_article(**overrides)
      cover_image = overrides.delete(:cover_image)
      defaults = {
        slug: 'post', title: 'A Post', summary: 'A summary.', draft: false,
        intro: 'one two three four', body: 'five six',
        published_at: '2024-01-01T10:00:00Z', tags: %w[running marathon]
      }
      a = article(**defaults.merge(overrides))
      a.sys = OpenStruct.new(published_at: '2024-02-01T10:00:00Z', published_version: 1082)
      a.cover_image = cover_image
      a
    end

    it 'returns nil for drafts' do
      expect(article_schema(schema_article(draft: true))).to be_nil
    end

    it 'emits machine-readable facts and references the sitewide entities by @id' do
      schema = JSON.parse(article_schema(schema_article))
      expect(schema).to include(
        '@type' => 'BlogPosting',
        'inLanguage' => 'en-US',
        'isAccessibleForFree' => true,
        'wordCount' => 6,
        'timeRequired' => 'PT1M',
        'keywords' => %w[Running Marathon],
        'articleSection' => 'Running'
      )
      expect(schema['author']).to eq('@id' => 'https://example.com/about/#person')
      expect(schema['publisher']).to eq('@id' => 'https://example.com/#organization')
      expect(schema['isPartOf']).to eq('@id' => 'https://example.com/#website')
      expect(schema['mainEntityOfPage']).to eq('@type' => 'WebPage', '@id' => canonical_url)
    end

    it 'omits keywords when the article has no tags' do
      schema = JSON.parse(article_schema(schema_article(tags: [])))
      expect(schema).not_to have_key('keywords')
      expect(schema).not_to have_key('articleSection')
    end

    it 'folds each concept\'s synonyms into the keywords, deduped' do
      a = schema_article
      a.contentful_metadata = OpenStruct.new(tags: [
        OpenStruct.new(name: 'Ironman 70.3', synonyms: [ 'Half Ironman', '70.3' ]),
        OpenStruct.new(name: 'Race Reports', synonyms: [])
      ])
      schema = JSON.parse(article_schema(a))
      expect(schema['keywords']).to eq([ 'Ironman 70.3', 'Half Ironman', '70.3', 'Race Reports' ])
      expect(schema['articleSection']).to eq('Ironman 70.3')
    end

    it 'emits cover images as ImageObjects with dimensions' do
      cover = OpenStruct.new(url: '//images/cover.jpg')
      schema = JSON.parse(article_schema(schema_article(cover_image: cover)))
      expect(schema['image']).to all(include('@type' => 'ImageObject'))
      expect(schema['image'].map { |i| [ i['width'], i['height'] ] })
        .to eq([ [ 1000, 1000 ], [ 1600, 900 ], [ 1600, 1200 ] ])
    end

    it 'falls back to the generated Open Graph card when there is no cover image (e.g. a Short)' do
      schema = JSON.parse(article_schema(schema_article(cover_image: nil)))
      expect(schema['image']).to eq([ {
        '@type' => 'ImageObject',
        'url' => 'https://example.com/2024/01/01/post/og.png?v=1082',
        'width' => 1200,
        'height' => 630
      } ])
    end
  end

  describe '#breadcrumb_schema' do
    it 'builds a Home > Blog > title breadcrumb for both articles and shorts' do
      %w[Article Short].each do |type|
        schema = JSON.parse(breadcrumb_schema(article(slug: 'post', title: 'A Post', entry_type: type)))
        expect(schema['@type']).to eq('BreadcrumbList')
        expect(schema['itemListElement'].map { |i| i['name'] }).to eq(%w[Home Blog] + [ 'A Post' ])
      end
    end

    it 'returns nil for drafts and for non-article/short entries' do
      expect(breadcrumb_schema(article(slug: 'draft', draft: true))).to be_nil
      expect(breadcrumb_schema(article(slug: 'about', entry_type: 'Page'))).to be_nil
    end
  end

  describe '#breadcrumb_schema with a taxonomy trail' do
    include_context 'a taxonomy'

    it 'inserts the deepest trail between Blog and the article, numbered in order' do
      art = tagged_article(slug: 'post', title: 'A Post', concepts: [
        concept('gear', 'Gear', path: '/tagged/tech/gear/', parent_id: 'tech', scheme: 'topics')
      ])
      schema = JSON.parse(breadcrumb_schema(art))
      expect(schema['itemListElement'].map { |i| i['name'] }).to eq([ 'Home', 'Blog', 'Tech', 'Gear', 'A Post' ])
      expect(schema['itemListElement'].map { |i| i['position'] }).to eq([ 1, 2, 3, 4, 5 ])
      expect(schema['itemListElement'][2]['item']).to eq('https://example.com/tagged/tech/')
    end
  end
end
