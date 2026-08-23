require 'spec_helper'
require 'ostruct'
require 'padrino-helpers'
require 'hashie'

# RSpec includes the module under test, thus you can call the instance methods of SiteHelpers
# directly.
RSpec.describe SiteHelpers do
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

  # Other helper modules usually supply these methods. This file defines them, thus the test runs
  # the schema builders alone.
  def data = OpenStruct.new(site: @site || site)
  def site_icon_url(w:) = "https://example.com/icon-#{w}.png"
  def cdn_image_url(url, params = {}) = "#{url}?w=#{params[:w]}"

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
          OpenStruct.new(tag: OpenStruct.new(path: '/tagged/triathlon/ironman-703/', synonyms: [ 'Half Ironman', '70.3' ])),
          OpenStruct.new(tag: OpenStruct.new(path: '/tagged/running/', synonyms: [])),
          OpenStruct.new(tag: OpenStruct.new(path: '/tagged/triathlon/', synonyms: [ 'Multisport' ]))
        ],
        redirects: [ OpenStruct.new(from: '/tagged/multisport') ] # a configured redirect already claims this
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

  describe '#alternate_feed_links' do
    def data = OpenStruct.new(site: OpenStruct.new(meta_title: 'My Site'))
    def page_content = @pc
    def feed_title = 'My Site'
    def taxonomy_index = { 'triathlon' => { name: 'Triathlon', path: '/tagged/triathlon/' } }
    def published_post?(content) = %w[Article Short].include?(content.entry_type) && !content.draft

    it 'advertises only the main site feed when the page has no content' do
      @pc = nil
      expect(alternate_feed_links).to eq([ { href: 'https://example.com/feed.xml', title: 'My Site' } ])
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
      expect(alternate_feed_links).to eq([ { href: 'https://example.com/feed.xml', title: 'My Site' } ])
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

  describe '#copyright_start_year' do
    def data = OpenStruct.new(articles: @articles || [])

    it 'is the year of the earliest published article' do
      @articles = [
        OpenStruct.new(draft: false, published_at: '2024-03-01T00:00:00Z'),
        OpenStruct.new(draft: false, published_at: '2006-06-15T00:00:00Z'),
        OpenStruct.new(draft: true,  published_at: '2001-01-01T00:00:00Z')
      ]
      expect(copyright_start_year).to eq('2006')
    end

    it 'falls back to the current year when no articles are published yet' do
      @articles = [ OpenStruct.new(draft: true, published_at: '2024-01-01T00:00:00Z') ]
      expect(copyright_start_year).to eq(Time.current.year.to_s)
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
      expect(nodes['Person']).to include(
        '@id' => 'https://example.com/about#person',
        'name' => 'Jane Doe',
        'url' => 'https://example.com/about',
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

  # page_title tests `content.is_a?(Hash)`, and each true proxied content object is a Middleman
  # Mash, which is a Hash subclass with dot access. Hashie::Mash replaces one here.
  describe '#page_title' do
    def data = OpenStruct.new(site: OpenStruct.new(meta_title: 'My Site'))

    it "uses a content object's title" do
      expect(page_title(Hashie::Mash.new(title: 'A Post'))).to eq('A Post')
      expect(page_title(Hashie::Mash.new(title: 'Blog'))).to eq('Blog')
    end

    it 'falls back to the site meta title for the home page and when there is no content' do
      expect(page_title(Hashie::Mash.new(title: 'Home', is_home_page: true))).to eq('My Site')
      expect(page_title(nil)).to eq('My Site')
    end

    it 'uses a plain string directly as the title' do
      expect(page_title('Search')).to eq('Search')
    end

    it 'appends the site name on request, deduping when the title already is the site name' do
      expect(page_title('Search', include_site_name: true)).to eq('Search · My Site')
      expect(page_title(nil, include_site_name: true)).to eq('My Site')
    end

    it 'joins segments with a custom separator' do
      expect(page_title('Search', include_site_name: true, separator: ' | ')).to eq('Search | My Site')
    end
  end

  describe '#title_tag' do
    include Padrino::Helpers

    def data = OpenStruct.new(site: OpenStruct.new(meta_title: 'My Site'))

    it 'wraps the page title, with the site name appended, in a <title> element' do
      expect(title_tag(Hashie::Mash.new(title: 'A Post'))).to eq('<title>A Post · My Site</title>')
    end
  end

  describe '#page_content' do
    def current_page = OpenStruct.new(metadata: { locals: @locals })

    it 'reads the proxied content object out of the page metadata locals' do
      content = OpenStruct.new(title: 'A Post')
      @locals = { content: content }
      expect(page_content).to equal(content)
    end

    it 'is nil when the page has no locals' do
      @locals = nil
      expect(page_content).to be_nil
    end
  end

  describe '#meta_title_source' do
    def current_page = OpenStruct.new(metadata: { locals: @locals }, data: OpenStruct.new(title: @frontmatter_title))

    it 'prefers the proxied content object over the frontmatter title' do
      content = OpenStruct.new(title: 'A Post')
      @locals = { content: content }
      @frontmatter_title = 'Frontmatter Title'
      expect(meta_title_source).to equal(content)
    end

    it 'falls back to the frontmatter title string' do
      @locals = nil
      @frontmatter_title = 'Frontmatter Title'
      expect(meta_title_source).to eq('Frontmatter Title')
    end

    it 'is nil when the page has neither content nor a frontmatter title' do
      @locals = nil
      @frontmatter_title = ''
      expect(meta_title_source).to be_nil
    end
  end

  describe '#meta_description' do
    # content_summary is in this module but it needs data.site. This file stubs it, thus the test
    # covers the order of the values only.
    def content_summary(content) = "Summary of #{content.title}."
    def current_page = OpenStruct.new(metadata: { locals: @locals }, data: OpenStruct.new(summary: @frontmatter_summary))

    it 'uses the content summary when the page has a content object' do
      @locals = { content: OpenStruct.new(title: 'A Post') }
      @frontmatter_summary = 'Ignored.'
      expect(meta_description).to eq('Summary of A Post.')
    end

    it 'falls back to the frontmatter summary' do
      @locals = nil
      @frontmatter_summary = 'A page about things.'
      expect(meta_description).to eq('A page about things.')
    end

    it 'is nil when the page has neither' do
      @locals = nil
      @frontmatter_summary = nil
      expect(meta_description).to be_nil
    end
  end

  describe '#copyright_years' do
    def data = OpenStruct.new(articles: [ OpenStruct.new(draft: false, published_at: '2006-06-15T00:00:00Z') ])

    it 'spans from the earliest publish year to the current year, joined with an en dash' do
      expect(copyright_years).to eq("2006–#{Time.current.year}")
    end
  end

  describe '#live_update_attrs' do
    it 'pins the exact attribute cluster the web↔api live-update contract requires' do
      attrs = live_update_attrs('/widgets/weather/current')
      expect(attrs).to eq('data-controller="live-update" data-live-update-url-value="/widgets/weather/current" data-live-update-placeholder-value="true" aria-busy="true" data-action="visibilitychange@document->live-update#handleVisibilityChange"')
      expect(attrs).to be_html_safe
    end

    # The placeholder flag tells the controller that this element holds a skeleton, and not real
    # content. Thus the controller fetches on connect, and it removes the element if that fetch
    # fails, and the element does not stay. The api fragment that replaces it must NOT have the
    # flag, because a temporary failure would then delete content on the page. For that reason only
    # the placeholder side writes it.
    it 'marks the element a placeholder, since only the placeholder side of the contract does' do
      expect(live_update_attrs('/widgets/whoop')).to include('data-live-update-placeholder-value="true"')
    end

    # An element that the build renders with real content, that is, the upcoming-races section,
    # does not have the flag: with the flag, a temporary fetch failure would delete that content.
    # It still fetches on connect, because the controller counts a URL with no fetch as old.
    it 'omits the placeholder flag and aria-busy for a statically rendered element' do
      attrs = live_update_attrs('/widgets/events/upcoming', placeholder: false)
      expect(attrs).to eq('data-controller="live-update" data-live-update-url-value="/widgets/events/upcoming" data-action="visibilitychange@document->live-update#handleVisibilityChange"')
      expect(attrs).to be_html_safe
    end
  end

  describe '#social_media_link' do
    include Padrino::Helpers

    # icon_svg is in IconHelpers and it reads data.icons. This file replaces it with a marker that
    # you can see. It is html_safe, as it is in the template render path, where the SVG goes into
    # the page with no escape. It gives a blank value for 'obscuresite', to test the code for a
    # brand icon that is absent.
    def icon_svg(family, style, icon_id)
      return '' if icon_id == 'obscuresite'
      %(<svg data-icon="#{family}/#{style}/#{icon_id}"></svg>).html_safe
    end

    it 'renders the feed item as a clipboard-copy button with the RSS icon' do
      expect(social_media_link(title: 'Feed', destination: '/feed.xml')).to eq(
        '<a title="Subscribe to the feed" aria-label="Subscribe to the feed" data-controller="clipboard" ' \
        'data-action="click-&gt;clipboard#copy" ' \
        'data-clipboard-success-message-value="The link to the feed has been copied to your clipboard." ' \
        'rel="me noopener" target="_blank" href="/feed.xml"><svg data-icon="classic/solid/rss"></svg></a>'
      )
    end

    it 'renders a normal profile link with the brand icon, follow labels, and new-tab attributes' do
      expect(social_media_link(title: 'Bluesky', destination: 'https://bsky.app/x', css_class: 'social')).to eq(
        '<a title="Follow on Bluesky" aria-label="Follow on Bluesky" rel="me noopener" target="_blank" ' \
        'class="social" href="https://bsky.app/x"><svg data-icon="classic/brands/bluesky"></svg></a>'
      )
    end

    it 'drops target and noopener when the link opens in the same tab' do
      expect(social_media_link(title: 'Mastodon', destination: 'https://m.test/x', open_in_new_tab: false)).to eq(
        '<a title="Follow on Mastodon" aria-label="Follow on Mastodon" rel="me" ' \
        'href="https://m.test/x"><svg data-icon="classic/brands/mastodon"></svg></a>'
      )
    end

    it 'falls back to the generic link icon when no brand icon exists' do
      expect(social_media_link(title: 'ObscureSite', destination: 'https://o.test/x')).to eq(
        '<a title="Follow on ObscureSite" aria-label="Follow on ObscureSite" rel="me noopener" target="_blank" ' \
        'href="https://o.test/x"><svg data-icon="classic/solid/link"></svg></a>'
      )
    end
  end

  describe '#shortcut_link' do
    include Padrino::Helpers

    it 'renders the feed item as a clipboard-copy link instead of a plain navigation' do
      item = OpenStruct.new(title: 'Feed', destination: '/feed.xml')
      # The order of the attributes comes from the shared FEED_CLIPBOARD_ATTRS: controller, action,
      # and message.
      expect(shortcut_link(item)).to eq(
        '<a href="/feed.xml" data-controller="clipboard" ' \
        'data-action="click-&gt;clipboard#copy" ' \
        'data-clipboard-success-message-value="The link to the feed has been copied to your clipboard.">Feed</a>'
      )
    end

    it 'adds target and noopener for items that open in a new tab' do
      item = OpenStruct.new(title: 'GitHub', destination: 'https://github.com/x', open_in_new_tab: true)
      expect(shortcut_link(item)).to eq('<a href="https://github.com/x" rel="noopener" target="_blank">GitHub</a>')
    end

    it 'renders everything else as a plain link' do
      item = OpenStruct.new(title: 'About', destination: '/about', open_in_new_tab: false)
      expect(shortcut_link(item)).to eq('<a href="/about">About</a>')
    end

    context 'when a page renders' do
      # A destination comes from Contentful, thus it can have a slash at the end or no slash, and
      # current_page.url always has one.
      def current_page = OpenStruct.new(url: '/about/')

      it 'marks the link to this page with aria-current, with or without the slash' do
        %w[/about /about/].each do |destination|
          item = OpenStruct.new(title: 'About', destination: destination, open_in_new_tab: false)
          expect(shortcut_link(item)).to eq('<a href="' + destination + '" aria-current="page">About</a>')
        end
      end

      it 'leaves another page, an absolute URL, and the feed with no aria-current' do
        [
          OpenStruct.new(title: 'Contact', destination: '/contact/', open_in_new_tab: false),
          OpenStruct.new(title: 'GitHub', destination: 'https://github.com/x', open_in_new_tab: true),
          OpenStruct.new(title: 'Feed', destination: '/feed.xml')
        ].each { |item| expect(shortcut_link(item)).not_to include('aria-current') }
      end

      it 'ignores a query and a fragment on the destination' do
        item = OpenStruct.new(title: 'About', destination: '/about/?utm=1#bio', open_in_new_tab: false)
        expect(shortcut_link(item)).to include('aria-current="page"')
      end
    end
  end

  describe 'plausible proxy helpers' do
    around do |example|
      original = ENV['PLAUSIBLE_SCRIPT_URL']
      example.run
    ensure
      original.nil? ? ENV.delete('PLAUSIBLE_SCRIPT_URL') : ENV['PLAUSIBLE_SCRIPT_URL'] = original
    end

    it 'exposes the fixed first-party proxy paths' do
      expect(plausible_script_path).to eq('/pa/script.js')
      expect(plausible_event_path).to eq('/pa/event')
    end

    it 'is installed only when the upstream script URL is configured' do
      ENV.delete('PLAUSIBLE_SCRIPT_URL')
      expect(plausible_installed?).to be(false)
      ENV['PLAUSIBLE_SCRIPT_URL'] = 'https://plausible.example/js/script.js'
      expect(plausible_installed?).to be(true)
    end
  end

  # ⚠️ The division into static rules and dynamic rules is a rule that a change can break, and it is
  # not a style choice. The Cloudflare parser latches at the first dynamic rule and counts each rule
  # after it, exact matches included, against the limit of 100 dynamic rules. This code was in
  # redirects.erb, and you cannot test a template.
  describe '#partitioned_redirects' do
    def taxonomy_synonym_redirects
      [ { from: '/tagged/half-ironman', to: '/tagged/triathlon/ironman-703/', status: 301 } ]
    end

    def data
      OpenStruct.new(redirects: @redirects || [])
    end

    def redirect(from, to, status = 301)
      OpenStruct.new(from: from, to: to, status: status)
    end

    it 'emits every exact-match rule before any splat or placeholder rule' do
      @redirects = [
        redirect('/old-splat/*', '/new/:splat'),
        redirect('/exact-one', '/new-one'),
        redirect('/with/:placeholder', '/other/:placeholder'),
        redirect('/exact-two', '/new-two')
      ]

      static_rules, dynamic_rules = partitioned_redirects

      expect(static_rules.map { |r| r[:from] }).to eq([ '/tagged/half-ironman', '/exact-one', '/exact-two' ])
      expect(dynamic_rules.map { |r| r[:from] })
        .to eq([ '/.well-known/host-meta*', '/.well-known/webfinger*', '/old-splat/*', '/with/:placeholder' ])
    end

    it 'counts the taxonomy synonym redirects as static' do
      static_rules, _ = partitioned_redirects

      expect(static_rules.map { |r| r[:from] }).to include('/tagged/half-ironman')
    end

    # Both stop a deploy (code 100324), and a Contentful entry can cause them.
    it 'drops an absolute-URL source' do
      @redirects = [ redirect('https://old.example.com/post', '/post') ]

      expect(partitioned_redirects.flatten.map { |r| r[:from] }).not_to include('https://old.example.com/post')
    end

    it 'drops a 200 proxy rewrite pointing at an absolute URL' do
      @redirects = [
        redirect('/proxied', 'https://upstream.example.com/thing', 200),
        redirect('/proxied-relative', '/thing', 200)
      ]

      froms = partitioned_redirects.flatten.map { |r| r[:from] }
      expect(froms).not_to include('/proxied')
      expect(froms).to include('/proxied-relative')
    end
  end

  describe '#dynamic_redirect_source?' do
    it 'is true for a splat or a :placeholder, false for an exact path' do
      expect(dynamic_redirect_source?('/a/*')).to be(true)
      expect(dynamic_redirect_source?('/a/:name')).to be(true)
      expect(dynamic_redirect_source?('/a/b')).to be(false)
      expect(dynamic_redirect_source?('/a/b.html')).to be(false)
    end

    # This matches too much, on purpose: a colon with a letter after it counts at each position,
    # thus a source that only looks like a placeholder becomes a dynamic rule. A static rule that
    # this code calls dynamic causes no damage. A dynamic rule that this code calls static stops the
    # deploy.
    it 'treats a mid-segment colon as a placeholder' do
      expect(dynamic_redirect_source?('/a:b')).to be(true)
    end
  end

  # No test covered these two, and split(':') with no limit removed the middle of a title with more
  # than one colon, and gave no message.
  describe '#feed_title and #feed_subtitle' do
    def data = OpenStruct.new(site: OpenStruct.new(meta_title: @meta_title))

    it 'splits the meta title on the first colon' do
      @meta_title = 'Kona: A blog about triathlon'
      expect(feed_title).to eq('Kona')
      expect(feed_subtitle).to eq('A blog about triathlon')
    end

    it 'keeps every later colon in the subtitle' do
      @meta_title = 'Kona: Swim: Bike: Run'
      expect(feed_title).to eq('Kona')
      expect(feed_subtitle).to eq('Swim: Bike: Run')
    end

    it 'has no subtitle when the title has no colon' do
      @meta_title = 'Kona'
      expect(feed_title).to eq('Kona')
      expect(feed_subtitle).to be_nil
    end
  end
end
