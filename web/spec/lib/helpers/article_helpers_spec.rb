require 'spec_helper'

# spec_helper.rb includes each helper module, thus an example calls the instance methods of
# ArticleHelpers directly.
RSpec.describe ArticleHelpers do
  include_context 'default helper stubs'
  include_context 'article doubles'

  describe '#article_word_count' do
    it 'counts words across the intro and body' do
      a = article(slug: 'a', intro: 'one two three', body: 'four five')
      expect(article_word_count(a)).to eq(5)
    end

    it 'ignores a blank body' do
      a = article(slug: 'a', intro: 'one two three four', body: nil)
      expect(article_word_count(a)).to eq(4)
    end
  end

  describe '#llms_articles' do
    it 'includes only indexable, non-draft, full articles, newest first' do
      corpus = [
        article(slug: 'keep-new', published_at: '2024-03-01T00:00:00Z'),
        article(slug: 'short', entry_type: 'Short'),
        article(slug: 'draft', draft: true),
        article(slug: 'noindex', index_in_search_engines: false),
        article(slug: 'keep-old', published_at: '2024-01-01T00:00:00Z')
      ]
      stub_corpus(corpus)
      # data.articles already has the newest article first, thus the helper keeps the input order.
      expect(llms_articles.map(&:slug)).to eq(%w[keep-new keep-old])
    end

    it 'caps the list at the requested count' do
      stub_corpus(12.times.map { |i| article(slug: "a#{i}") })
      expect(llms_articles(count: 5).size).to eq(5)
    end
  end

  describe '#draft_badge' do
    def icon_svg(_family, _style, icon_id) = "<svg data-icon=\"#{icon_id}\"></svg>"

    it 'renders the highlight span with the typewriter icon' do
      expect(draft_badge).to eq('<span class="entry__highlight"><svg data-icon="typewriter"></svg> Draft</span>')
    end
  end

  describe '#article_permalink_timestamp' do
    include Padrino::Helpers

    it 'wraps the permalink anchor in a <time> carrying the ISO publish instant' do
      result = article_permalink_timestamp(article(slug: 'post', published_at: '2024-01-01T10:00:00Z'))
      expect(result).to start_with('<time datetime="2024-01-01T10:00:00+00:00">')
      expect(result).to end_with('</time>')
      expect(result).to include('data-publish-date-target="timestamp"')
      expect(result).to include('Monday, January 1, 2024')
    end

    it 'links to the directory-index URL, not the source path with index.html' do
      a = article(slug: 'post', published_at: '2024-01-01T10:00:00Z')
      a.path = '/2024/01/01/post/index.html'
      expect(article_permalink_timestamp(a)).to include('href="/2024/01/01/post/"')
    end

    # ⚠️ The page of the article renders this link too, and it points at that same page. Thus a
    # class attribute must be absent when the caller gives no class.
    it 'writes no class attribute with no link_class' do
      result = article_permalink_timestamp(article(slug: 'post', published_at: '2024-01-01T10:00:00Z'))
      expect(result).not_to include('class=')
    end

    it 'puts link_class on the anchor' do
      a = article(slug: 'post', published_at: '2024-01-01T10:00:00Z')
      expect(article_permalink_timestamp(a, link_class: 'tracking')).to include('class="tracking"')
    end
  end

  describe '#compute_article_word_count' do
    it 'counts whitespace-separated words across the intro and body' do
      a = article(slug: 'a', intro: "one two\nthree", body: 'four five')
      expect(compute_article_word_count(a)).to eq(5)
    end

    it 'ignores blank segments so a missing intro adds no words' do
      a = article(slug: 'a', intro: nil, body: 'one two')
      expect(compute_article_word_count(a)).to eq(2)
    end
  end

  describe '#reading_time_minutes' do
    it 'rounds the word count up to whole minutes at the default 200 wpm' do
      a = article(slug: 'a', intro: ([ 'word' ] * 250).join(' '))
      expect(reading_time_minutes(a)).to eq(2)
    end

    it 'reads a custom words-per-minute rate from READING_TIME_WPM' do
      a = article(slug: 'a', intro: ([ 'word' ] * 250).join(' '))
      stub_env('READING_TIME_WPM' => '100')
      expect(reading_time_minutes(a)).to eq(3)
    end

    it 'is a single minute for a very short post' do
      expect(reading_time_minutes(article(slug: 'a', intro: 'so short'))).to eq(1)
    end

    # A blank value, or a value that is not a positive number, gives the default and no division by
    # zero. `reading_time_minutes` gives the reason.
    it 'falls back to the default rate when READING_TIME_WPM is present but unusable' do
      a = article(slug: 'a', intro: ([ 'word' ] * 250).join(' '))
      [ '', '   ', 'abc', '0', '-5' ].each do |value|
        stub_env('READING_TIME_WPM' => value)
        expect(reading_time_minutes(a)).to eq(2), "expected the 200 wpm default for #{value.inspect}"
      end
    end
  end

  describe '#reading_time' do
    # Exactly N minutes at the default of 200 words each minute.
    def article_with_minutes(minutes)
      article(slug: "m#{minutes}", intro: ([ 'word' ] * (minutes * 200)).join(' '))
    end

    it 'formats the estimate as "A N-minute read"' do
      expect(reading_time(article_with_minutes(3))).to eq('A 3-minute read')
    end

    it 'uses "An" when the humanized minute count is eight, eleven, or eighteen' do
      expect(reading_time(article_with_minutes(8))).to eq('An 8-minute read')
      expect(reading_time(article_with_minutes(11))).to eq('An 11-minute read')
      expect(reading_time(article_with_minutes(18))).to eq('An 18-minute read')
    end

    it 'uses "An" for eighty too — its spoken form also starts with a vowel sound' do
      expect(reading_time(article_with_minutes(80))).to eq('An 80-minute read')
    end
  end

  describe '#recent_articles' do
    let(:corpus) do
      [
        article(slug: 'newest', published_at: '2024-05-01T00:00:00Z'),
        article(slug: 'short',  published_at: '2024-04-01T00:00:00Z', entry_type: 'Short'),
        article(slug: 'draft',  published_at: '2024-03-15T00:00:00Z', draft: true),
        article(slug: 'second', published_at: '2024-03-01T00:00:00Z'),
        article(slug: 'third',  published_at: '2024-02-01T00:00:00Z'),
        article(slug: 'fourth', published_at: '2024-01-20T00:00:00Z'),
        article(slug: 'fifth',  published_at: '2024-01-10T00:00:00Z')
      ]
    end

    it 'returns the four newest full articles, skipping drafts and Shorts' do
      stub_corpus(corpus)
      expect(recent_articles.map(&:slug)).to eq(%w[newest second third fourth])
    end

    it 'excludes a given article by path and honors a custom count' do
      stub_corpus(corpus)
      expect(recent_articles(count: 2, exclude: corpus[0]).map(&:slug)).to eq(%w[second third])
    end
  end

  describe '#feed_articles' do
    it 'includes Shorts but not drafts, preserving newest-first order' do
      stub_corpus([
        article(slug: 'newest', published_at: '2024-03-01T00:00:00Z'),
        article(slug: 'short',  published_at: '2024-02-01T00:00:00Z', entry_type: 'Short'),
        article(slug: 'draft',  published_at: '2024-01-15T00:00:00Z', draft: true),
        article(slug: 'oldest', published_at: '2024-01-01T00:00:00Z')
      ])
      expect(feed_articles.map(&:slug)).to eq(%w[newest short oldest])
    end

    it 'caps the list at the requested count' do
      stub_corpus(6.times.map { |i| article(slug: "a#{i}") })
      expect(feed_articles(count: 4).size).to eq(4)
    end
  end

  # ⚠️ These two groups get the content object in the way that Middleman gives it: through
  # `current_page.metadata[:locals][:content]`, with the real `page_content` of SiteHelpers. Do not
  # replace that with a `def content` stub. Such a stub defines a *method*, which makes
  # `defined?(content)` true and gives a pass against a binding that Middleman never makes. Code
  # that reads `defined?(content)` then passes here, and a search engine can index each draft.
  def page_content = SiteHelpers.instance_method(:page_content).bind_call(self)
  def current_page = OpenStruct.new(url: '/2024/01/01/post/', metadata: { locals: @page_locals || {} }, data: OpenStruct.new(@page_data || {}))

  describe '#canonical_url' do
    # The top of this file makes `canonical_url` a plain stub for the schema groups. This puts the
    # real module method back, thus this group runs the code of ArticleHelpers.
    def canonical_url = ArticleHelpers.instance_method(:canonical_url).bind_call(self)

    it 'is the full URL of the current page when the page has no content object' do
      expect(canonical_url).to eq('https://example.com/2024/01/01/post/')
    end

    context 'when the page has a content object' do
      it "prefers the content's own canonical_url when present" do
        @page_locals = { content: OpenStruct.new(canonical_url: 'https://elsewhere.example/original/') }
        expect(canonical_url).to eq('https://elsewhere.example/original/')
      end

      it 'falls back to the current page URL when the content has none' do
        @page_locals = { content: OpenStruct.new(canonical_url: nil) }
        expect(canonical_url).to eq('https://example.com/2024/01/01/post/')
      end
    end
  end

  describe '#hide_from_search_engines?' do
    def production? = @production.nil? ? true : @production

    it 'hides everything outside production' do
      @production = false
      @page_locals = { content: article(slug: 'post') }
      expect(hide_from_search_engines?).to be(true)
    end

    it 'hides a draft' do
      @page_locals = { content: article(slug: 'post', draft: true) }
      expect(hide_from_search_engines?).to be(true)
    end

    it 'hides an entry opted out of indexing' do
      @page_locals = { content: article(slug: 'post', index_in_search_engines: false) }
      expect(hide_from_search_engines?).to be(true)
    end

    it 'indexes a published, opted-in entry' do
      @page_locals = { content: article(slug: 'post') }
      expect(hide_from_search_engines?).to be(false)
    end

    it 'indexes a page with no content object, e.g. a static template' do
      expect(hide_from_search_engines?).to be(false)
    end

    # The 404 page has no proxied content object, thus its flag is in the frontmatter.
    it 'hides a content-object-less page whose frontmatter opts out' do
      @page_data = { index_in_search_engines: false }
      expect(hide_from_search_engines?).to be(true)
    end
  end

  describe '#entry_dom_id / #entry_heading_id' do
    it 'derives the entry and heading DOM ids from the parameterized Contentful id' do
      entry = article(slug: 'post')
      entry.sys = OpenStruct.new(id: '1QxUv2jHbvRd9OqMxOneqZ')
      # parameterize makes a Contentful id lowercase. This is an accepted cost: two ids that are
      # different only in case would become one, but a change now would change the DOM id on each
      # published page.
      expect(entry_dom_id(entry)).to eq('entry-1qxuv2jhbvrd9oqmxoneqz')
      expect(entry_heading_id(entry)).to eq('hed-1qxuv2jhbvrd9oqmxoneqz')
    end

    # The related-articles section gives each card a scope, because read_next renders more summary
    # cards for the same entries on the same page.
    it 'prefixes both ids with a scope when one is given' do
      entry = article(slug: 'post')
      entry.sys = OpenStruct.new(id: '1QxUv2jHbvRd9OqMxOneqZ')
      expect(entry_dom_id(entry, scope: 'you-may-also-like')).to eq('entry-you-may-also-like-1qxuv2jhbvrd9oqmxoneqz')
      expect(entry_heading_id(entry, scope: 'you-may-also-like')).to eq('hed-you-may-also-like-1qxuv2jhbvrd9oqmxoneqz')
    end
  end
end
