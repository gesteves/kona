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

    # ⚠️ Feed autodiscovery has no order of preference, thus a tag feed on an article page can send
    # a reader to a narrow feed.
    it 'advertises only the main site feed on an article page, whatever its tags' do
      @pc = OpenStruct.new(
        template: '/article.html', entry_type: 'Article', draft: false,
        contentful_metadata: OpenStruct.new(tags: [
          OpenStruct.new(id: 'triathlon', name: 'Triathlon', path: '/tagged/triathlon/'),
          OpenStruct.new(id: 'half-distance', name: 'Half Distance', path: '/tagged/triathlon/half-distance/')
        ])
      )
      expect(alternate_feed_links).to eq([ { href: 'https://example.com/feed.xml', title: 'My Site' } ])
    end

    it 'advertises only the main site feed on a non-tag, non-post page' do
      @pc = OpenStruct.new(template: '/page.html', entry_type: 'Page', draft: false)
      expect(alternate_feed_links).to eq([ { href: 'https://example.com/feed.xml', title: 'My Site' } ])
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

  # page_title tests `content.is_a?(Hash)`, and each true proxied content object is a Middleman
  # Mash, which is a Hash subclass with dot access. Hashie::Mash replaces one here.
  describe '#content_summary' do
    def data = OpenStruct.new(site: OpenStruct.new(meta_description: 'Site'))

    # ⚠️ The Atom summary is plain text, thus the omission must be the character and not "...",
    # which smartypants turns into `&hellip;`.
    it 'cuts a long summary with a single ellipsis character' do
      long = OpenStruct.new(summary: 'word ' * 100, entry_type: 'Article', intro: nil)
      text = content_summary(long)
      expect(text.length).to be <= SiteHelpers::SUMMARY_LENGTH
      expect(text).to end_with('…')
      expect(text).not_to include('...')
    end
  end

  describe '#title_tag' do
    include Padrino::Helpers

    def data = OpenStruct.new(site: OpenStruct.new(meta_title: 'My Site'))

    it 'wraps the page title, with the site name appended, in a <title> element' do
      expect(title_tag(Hashie::Mash.new(title: 'A Post'))).to eq('<title>A Post · My Site</title>')
    end
  end

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

  describe '#sitemap_lastmod' do
    it 'keeps the time of a Contentful timestamp' do
      expect(sitemap_lastmod('2026-09-05T18:57:14.843Z')).to eq('2026-09-05T18:57:14+00:00')
    end

    it 'takes the DateTime that site_updated_at gives' do
      expect(sitemap_lastmod(DateTime.parse('2026-09-05T18:57:14Z'))).to eq('2026-09-05T18:57:14+00:00')
    end

    # ⚠️ IndexNow compares this string. With a date alone, a second edit of the same day
    # gives the same value, and no URL goes to the engines.
    it 'gives two values for two times of the same day' do
      morning = sitemap_lastmod('2026-09-05T08:00:00Z')
      evening = sitemap_lastmod('2026-09-05T20:00:00Z')
      expect(morning).not_to eq(evening)
    end
  end

  describe '#article_click_classes' do
    it 'makes the name class and the section class' do
      expect(article_click_classes('Recent Articles'))
        .to eq('plausible-event-name=Article+Click plausible-event-section=Recent+Articles')
    end

    # ⚠️ A space in a value must become a '+'. Without that, 'You May Also Like' is four class
    # names, and the script then reads a section of 'You'.
    it 'makes one class name from a section with a space' do
      expect(article_click_classes('You May Also Like'))
        .to eq('plausible-event-name=Article+Click plausible-event-section=You+May+Also+Like')
    end

    # ⚠️ The name class on its own sends an event with no section, and nothing shows that error.
    it 'gives nil for a blank section' do
      expect(article_click_classes(nil)).to be_nil
      expect(article_click_classes('')).to be_nil
    end
  end

  describe '#known_agent_rules' do
    let(:rules) { "User-agent: GPTBot\nDisallow: /" }

    def data = OpenStruct.new(@known_agents ? { known_agents: @known_agents } : {})

    it 'gives the rules and a blank line after them' do
      @known_agents = OpenStruct.new(robots_txt: rules)
      expect(known_agent_rules).to eq("#{rules}\n\n")
    end

    it 'removes the whitespace around the rules of the API' do
      @known_agents = OpenStruct.new(robots_txt: "\n#{rules}\n\n")
      expect(known_agent_rules).to eq("#{rules}\n\n")
    end

    # ⚠️ A failed import writes no data/known_agents.json, and `rake clobber` removes the file of
    # the last run. Without the guard, robots.txt.erb stops the build.
    it 'gives an empty string when the import wrote no file' do
      @known_agents = nil
      expect(known_agent_rules).to eq('')
    end

    it 'gives an empty string when the file holds no rules' do
      @known_agents = OpenStruct.new(robots_txt: '')
      expect(known_agent_rules).to eq('')
    end
  end
end
