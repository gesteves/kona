require 'spec_helper'
require 'ostruct'
require 'padrino-helpers'

# RSpec includes the module under test, thus you can call the instance methods of ArticleHelpers
# directly.
RSpec.describe ArticleHelpers do
  include_context 'default helper stubs'

  # The canonical URL of the article under test. The schema groups below share it.
  def canonical_url = 'https://example.com/2024/01/01/post/'

  # Makes an article double with the shape of a `data.articles` entry: dot access, and nested tags
  # and event.
  def article(slug:, title: 'Title', tags: [], published_at: '2024-01-01T10:00:00Z',
              entry_type: 'Article', draft: false, index_in_search_engines: true,
              intro: nil, body: nil, summary: nil)
    OpenStruct.new(
      slug: slug,
      path: "/#{slug}/",
      title: title,
      published_at: published_at,
      entry_type: entry_type,
      draft: draft,
      index_in_search_engines: index_in_search_engines,
      intro: intro,
      body: body,
      summary: summary,
      contentful_metadata: OpenStruct.new(tags: tags.map { |id| OpenStruct.new(id: id, name: id.capitalize) })
    )
  end

  # Sets the articles that `data.articles` returns.
  def stub_corpus(articles)
    @corpus = articles
  end

  # The helper needs this method, which another module usually supplies. This file defines it
  # directly, thus a verifying double does not refuse a stub of a method that this object does not
  # have.
  def data
    OpenStruct.new(articles: @corpus || [])
  end

  describe '#adjacent_articles' do
    # data.articles comes with the newest article first, thus index-1 is newer and index+1 is
    # older.
    let(:corpus) do
      [
        article(slug: 'newest', published_at: '2024-03-01T00:00:00Z'),
        article(slug: 'middle', published_at: '2024-02-01T00:00:00Z'),
        article(slug: 'oldest', published_at: '2024-01-01T00:00:00Z')
      ]
    end

    it 'returns the newer and older neighbors for a middle entry' do
      stub_corpus(corpus)
      result = adjacent_articles(corpus[1])
      expect(result[:newer].slug).to eq('newest')
      expect(result[:older].slug).to eq('oldest')
    end

    it 'has no newer neighbor for the newest entry' do
      stub_corpus(corpus)
      result = adjacent_articles(corpus[0])
      expect(result[:newer]).to be_nil
      expect(result[:older].slug).to eq('middle')
    end

    it 'has no older neighbor for the oldest entry' do
      stub_corpus(corpus)
      result = adjacent_articles(corpus[2])
      expect(result[:newer].slug).to eq('middle')
      expect(result[:older]).to be_nil
    end

    it 'includes Shorts in the sequence but excludes drafts' do
      mixed = [
        article(slug: 'newest', published_at: '2024-03-01T00:00:00Z'),
        article(slug: 'draft',  published_at: '2024-02-15T00:00:00Z', draft: true),
        article(slug: 'short',  published_at: '2024-02-01T00:00:00Z', entry_type: 'Short'),
        article(slug: 'oldest', published_at: '2024-01-01T00:00:00Z')
      ]
      stub_corpus(mixed)
      # The code removes the draft from the sequence, thus 'newest' is beside the Short.
      expect(adjacent_articles(mixed[0])[:older].slug).to eq('short')
      result = adjacent_articles(mixed[2])
      expect(result[:newer].slug).to eq('newest')
      expect(result[:older].slug).to eq('oldest')
    end

    it 'returns no neighbors when the entry is not in the published sequence' do
      stub_corpus(corpus)
      orphan = article(slug: 'draft-preview', draft: true)
      expect(adjacent_articles(orphan)).to eq(newer: nil, older: nil)
    end
  end

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

  describe '#article_schema' do
    # These methods are in other helper modules at run time. This file stubs them, thus the test
    # runs the schema builder alone.
    def content_summary(content) = content.summary
    def schema_entity_id(fragment, path: '/') = "https://example.com#{path == '/' ? '/' : "#{path}/"}##{fragment}"
    def cdn_image_url(url, params = {}) = "#{url}?w=#{params[:w]}&h=#{params[:h]}"
    def generate_open_graph_image_url(path, version) = "https://example.com#{path.chomp('/')}/og.png?v=#{version}"
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

  describe 'tag list rendering' do
    include Padrino::Helpers

    describe '#tag_list_icon' do
      def icon_svg(_family, _style, icon_id) = icon_id

      it 'picks the single-tag icon for one tag and the plural icon otherwise' do
        expect(tag_list_icon(1)).to eq('tag')
        expect(tag_list_icon(2)).to eq('tags')
      end
    end

    describe '#tag_chain_links' do
      it 'renders each chain as slash-separated listitem links, joining chains the same way' do
        html = tag_chain_links([ [ [ 'Triathlon', '/tagged/triathlon/' ], [ 'Half Distance', '/tagged/triathlon/half-distance/' ] ], [ [ 'Race Reports', '/tagged/race-reports/' ] ] ])
        separator = '<span class="entry__tag-separator" aria-hidden="true">/</span>'
        expect(html).to eq(
          '<span role="listitem"><a href="/tagged/triathlon/">Triathlon</a></span>' + separator +
          '<span role="listitem"><a href="/tagged/triathlon/half-distance/">Half Distance</a></span>' + separator +
          '<span role="listitem"><a href="/tagged/race-reports/">Race Reports</a></span>'
        )
      end
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
      ENV['READING_TIME_WPM'] = '100'
      expect(reading_time_minutes(a)).to eq(3)
    ensure
      ENV.delete('READING_TIME_WPM')
    end

    it 'is a single minute for a very short post' do
      expect(reading_time_minutes(article(slug: 'a', intro: 'so short'))).to eq(1)
    end

    # ⚠️ A GitHub Actions variable with no value becomes an EMPTY STRING. Thus the env key is
    # available and blank, the default of ENV.fetch never applies, `''.to_i` is 0, and the division
    # raised FloatDomainError on each article page. That stopped a production deploy. Only the
    # build ran that code, because nothing else divides by this value.
    it 'falls back to the default rate when READING_TIME_WPM is present but unusable' do
      a = article(slug: 'a', intro: ([ 'word' ] * 250).join(' '))
      [ '', '   ', 'abc', '0', '-5' ].each do |value|
        ENV['READING_TIME_WPM'] = value
        expect(reading_time_minutes(a)).to eq(2), "expected the 200 wpm default for #{value.inspect}"
      end
    ensure
      ENV.delete('READING_TIME_WPM')
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
  # `defined?(content)` true and gives a pass against a binding that Middleman never makes. That is
  # what hid the code that read `defined?(content)` and sent each draft to production where a
  # search engine could index it.
  def page_content = SiteHelpers.instance_method(:page_content).bind_call(self)
  def current_page = OpenStruct.new(url: '/2024/01/01/post/', metadata: { locals: @page_locals || {} }, data: OpenStruct.new(@page_data || {}))

  describe '#canonical_url' do
    # The group above makes `canonical_url` a plain stub for the schema groups. Put the real module
    # method back here, thus this group runs the code of ArticleHelpers.
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
      # parameterize makes the text lowercase, thus a Contentful id with two cases becomes
      # lowercase. This is an accepted cost, and the helper says so: two ids that are different only
      # in case would become one, but a change now would change the DOM id on each published
      # page.
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

  describe '#related_articles' do
    # This group needs `data.related` and also `data.articles`.
    def data
      fields = { articles: @corpus || [] }
      fields[:related] = @related unless @related.nil?
      OpenStruct.new(fields)
    end

    def entry(slug, id)
      a = article(slug: slug)
      a.sys = OpenStruct.new(id: id)
      a
    end

    let(:corpus) { [ entry('a', 'id-a'), entry('b', 'id-b'), entry('c', 'id-c') ] }

    before { stub_corpus(corpus) }

    it 'resolves the imported ids to entries, in the order the api ranked them' do
      @related = { 'id-a' => %w[id-c id-b] }
      expect(related_articles(corpus.first).map(&:slug)).to eq(%w[c b])
    end

    it 'takes at most `count`' do
      @related = { 'id-a' => %w[id-c id-b] }
      expect(related_articles(corpus.first, count: 1).map(&:slug)).to eq([ 'c' ])
    end

    # The three causes of an empty result all remove the section, and none of them raises.
    it 'returns nothing when the import never ran' do
      @related = nil
      expect(related_articles(corpus.first)).to eq([])
    end

    it 'returns nothing when the entry has no stored embedding' do
      @related = { 'id-b' => [ 'id-c' ] }
      expect(related_articles(corpus.first)).to eq([])
    end

    # The code removes a neighbor that became unpublished after the calculation of the list. It
    # does not render a blank card.
    it 'drops ids that no longer resolve to a published entry' do
      @related = { 'id-a' => %w[id-gone id-b] }
      expect(related_articles(corpus.first).map(&:slug)).to eq([ 'b' ])
    end
  end

  # The helpers that read the taxonomy need tags with path and parent_id, and not only id and name,
  # and they need a data.tags tree. Thus this group defines larger builders that replace the ones
  # above.
  describe 'taxonomy-aware helpers' do
    # A concept "tag" as it is on an article and in data.tags: id, name, short_name, path, parent,
    # scheme, and the archive count, which the breadcrumb code uses to select between two
    # concepts.
    def concept(id, name, path:, parent_id: nil, scheme: nil, count: 0, short_name: nil)
      OpenStruct.new(id: id, name: name, short_name: short_name || name, path: path, parent_id: parent_id, scheme: scheme, entry_count: count)
    end

    # An article whose contentful_metadata.tags are complete concept doubles.
    def tagged_article(slug:, concepts:, **opts)
      a = article(slug: slug, **opts)
      a.contentful_metadata = OpenStruct.new(tags: concepts)
      a
    end

    # Short names for the concepts below. They agree with the data.tags tree.
    def cda = concept('ironman-703-coeur-dalene', 'Ironman 70.3 Coeur d’Alene', path: '/tagged/triathlon/half-distance/ironman-703-coeur-dalene/', parent_id: 'half-distance', scheme: 'sports')
    def race_reports = concept('race-reports', 'Race Reports', path: '/tagged/race-reports/', scheme: 'topics')

    # data.tags is the same as the tag pages that the build makes: Sports (Triathlon › Half
    # Distance › one race) and Topics (Race Reports, News, Reviews, and Tech › Gear). Each concept
    # has its scheme and its archive count.
    def data
      tags = [
        concept('triathlon', 'Triathlon', path: '/tagged/triathlon/', scheme: 'sports', count: 20),
        concept('half-distance', 'Half Distance', path: '/tagged/triathlon/half-distance/', parent_id: 'triathlon', scheme: 'sports', count: 10),
        concept('ironman-703-coeur-dalene', 'Ironman 70.3 Coeur d’Alene', path: '/tagged/triathlon/half-distance/ironman-703-coeur-dalene/', parent_id: 'half-distance', scheme: 'sports', count: 3),
        concept('triathlon-other', 'Other', path: '/tagged/triathlon/triathlon-other/', parent_id: 'triathlon', scheme: 'sports', count: 2),
        concept('escape-from-alcatraz-triathlon', 'Escape from Alcatraz Triathlon', short_name: 'Escape from Alcatraz', path: '/tagged/triathlon/triathlon-other/escape-from-alcatraz-triathlon/', parent_id: 'triathlon-other', scheme: 'sports', count: 2),
        concept('running', 'Running', path: '/tagged/running/', scheme: 'sports', count: 8),
        concept('race-reports', 'Race Reports', path: '/tagged/race-reports/', scheme: 'topics', count: 12),
        concept('news', 'News', path: '/tagged/news/', scheme: 'topics', count: 18),
        concept('reviews', 'Reviews', path: '/tagged/reviews/', scheme: 'topics', count: 1),
        concept('tech', 'Tech', path: '/tagged/tech/', scheme: 'topics', count: 6),
        concept('gear', 'Gear', path: '/tagged/tech/gear/', parent_id: 'tech', scheme: 'topics', count: 3)
      ].map { |c| OpenStruct.new(tag: c) }
      OpenStruct.new(articles: @corpus || [], tags: tags)
    end

    describe '#taxonomy_trail' do
      it 'returns the deepest chain across schemes (the Sports race chain for a report)' do
        art = tagged_article(slug: 'cda', concepts: [ cda, race_reports ])
        expect(taxonomy_trail(art).map { |n| n[:name] }).to eq([ 'Triathlon', 'Half Distance', 'Ironman 70.3 Coeur d’Alene' ])
      end

      it 'breaks depth ties by archive popularity (News beats Reviews)' do
        art = tagged_article(slug: 'x', concepts: [
          concept('reviews', 'Reviews', path: '/tagged/reviews/', scheme: 'topics'),
          concept('news', 'News', path: '/tagged/news/', scheme: 'topics')
        ])
        expect(taxonomy_trail(art).map { |n| n[:name] }).to eq([ 'News' ])
      end

      it 'is empty when the article has no taxonomy' do
        expect(taxonomy_trail(article(slug: 'x'))).to eq([])
      end
    end

    describe '#breadcrumb_schema with a taxonomy trail' do
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

    describe '#race_concept_id / #related_race_reports' do
      it 'is the deepest Sports concept — a specific race (chain length ≥ 3)' do
        expect(race_concept_id(tagged_article(slug: 'cda', concepts: [ cda, race_reports ]))).to eq('ironman-703-coeur-dalene')
        # An article with a distance only, and no race, has no race concept.
        half = concept('half-distance', 'Half Distance', path: '/tagged/triathlon/half-distance/', parent_id: 'triathlon', scheme: 'sports')
        expect(race_concept_id(tagged_article(slug: 'general', concepts: [ half ]))).to be_nil
      end

      it 'groups race reports by their shared race concept, excluding non-reports and Shorts' do
        a2025 = tagged_article(slug: 'cda-2025', concepts: [ race_reports, cda ], published_at: '2025-06-01T00:00:00Z')
        a2024 = tagged_article(slug: 'cda-2024', concepts: [ race_reports, cda ], published_at: '2024-06-01T00:00:00Z')
        short = tagged_article(slug: 'cda-short', concepts: [ race_reports, cda ], entry_type: 'Short', published_at: '2023-06-01T00:00:00Z')
        preview = tagged_article(slug: 'cda-preview', concepts: [ cda ], published_at: '2023-01-01T00:00:00Z') # same race, not a report
        other = tagged_article(slug: 'other', concepts: [ concept('running', 'Running', path: '/tagged/running/', scheme: 'sports') ], published_at: '2025-01-01T00:00:00Z')
        stub_corpus([ a2025, a2024, short, preview, other ])

        expect(related_race_reports(a2025).map(&:slug)).to eq([ 'cda-2024' ])
      end

      it 'returns nothing when the article has no race concept' do
        stub_corpus([ tagged_article(slug: 'solo', concepts: [ concept('running', 'Running', path: '/tagged/running/', scheme: 'sports') ]) ])
        expect(related_race_reports(article(slug: 'solo'))).to eq([])
      end
    end

    describe '#recirculation_sections' do
      # This group needs data.related as well as data.articles and data.tags.
      def data
        base = super
        OpenStruct.new(articles: base.articles, tags: base.tags, related: @related || {})
      end

      # A tagged article that also has a sys id, thus data.related can name it.
      def entry(slug, id, concepts: [], **opts)
        a = tagged_article(slug: slug, concepts: concepts, **opts)
        a.sys = OpenStruct.new(id: id)
        a
      end

      # ⚠️ This is the reason for the change: the two sections excluded each other, thus this
      # article showed one card where five were possible.
      it 'renders the race reports and the related entries together' do
        a = entry('cda-2026', 'id-a', concepts: [ race_reports, cda ], published_at: '2026-06-01T00:00:00Z')
        sibling = entry('cda-2025', 'id-sib', concepts: [ race_reports, cda ], published_at: '2025-06-01T00:00:00Z')
        near = %w[id-n1 id-n2 id-n3 id-n4].each_with_index.map { |id, i| entry("near-#{i}", id) }
        stub_corpus([ a, sibling, *near ])
        @related = { 'id-a' => %w[id-n1 id-n2 id-n3 id-n4] }

        sections = recirculation_sections(a)
        expect(sections[:reports].map(&:slug)).to eq([ 'cda-2025' ])
        expect(sections[:related].map(&:slug)).to eq(%w[near-0 near-1 near-2 near-3])
      end

      # A report of the same race is often also the nearest entry by meaning. The same card in the
      # two sections would give two DOM ids that are the same.
      it 'never lists an entry in both sections, and never the article itself' do
        a = entry('cda-2026', 'id-a', concepts: [ race_reports, cda ], published_at: '2026-06-01T00:00:00Z')
        sibling = entry('cda-2025', 'id-sib', concepts: [ race_reports, cda ], published_at: '2025-06-01T00:00:00Z')
        other = entry('other', 'id-o')
        stub_corpus([ a, sibling, other ])
        @related = { 'id-a' => %w[id-sib id-a id-o] }

        sections = recirculation_sections(a)
        expect(sections[:reports].map(&:slug)).to eq([ 'cda-2025' ])
        expect(sections[:related].map(&:slug)).to eq([ 'other' ])
      end

      # ⚠️ The api sends more neighbors than one section shows (RelatedController::COUNT), because
      # the dedup above removes some of them. Without that headroom the second section is short.
      it 'still fills the related section when the reports also appear in the related list' do
        a = entry('cda-2026', 'id-a', concepts: [ race_reports, cda ], published_at: '2026-06-01T00:00:00Z')
        sibs = %w[2025 2024].each_with_index.map do |year, i|
          entry("cda-#{year}", "id-sib#{i}", concepts: [ race_reports, cda ], published_at: "#{year}-06-01T00:00:00Z")
        end
        near = (1..4).map { |i| entry("near-#{i}", "id-n#{i}") }
        stub_corpus([ a, *sibs, *near ])
        # The api ranks the two reports first, because their meaning is nearest.
        @related = { 'id-a' => %w[id-sib0 id-sib1 id-n1 id-n2 id-n3 id-n4] }

        sections = recirculation_sections(a)
        expect(sections[:reports].size).to eq(2)
        expect(sections[:related].map(&:slug)).to eq(%w[near-1 near-2 near-3 near-4])
      end

      it 'gives the related entries only when the article has no race' do
        a = entry('post', 'id-a')
        other = entry('other', 'id-o')
        stub_corpus([ a, other ])
        @related = { 'id-a' => [ 'id-o' ] }

        sections = recirculation_sections(a)
        expect(sections[:reports]).to eq([])
        expect(sections[:related].map(&:slug)).to eq([ 'other' ])
      end

      # Two empty lists render no section at all.
      it 'is empty when the article has no neighbor' do
        a = entry('lonely', 'id-a')
        stub_corpus([ a ])

        expect(recirculation_sections(a)).to eq({ reports: [], related: [] })
      end
    end

    describe '#tag_breadcrumb_chains' do
      def triathlon = concept('triathlon', 'Triathlon', path: '/tagged/triathlon/', scheme: 'sports')
      def half = concept('half-distance', 'Half Distance', path: '/tagged/triathlon/half-distance/', parent_id: 'triathlon', scheme: 'sports')

      it 'builds each leaf’s root→leaf chain, deepest first' do
        art = tagged_article(slug: 'cda', concepts: [ triathlon, half, cda, race_reports ])
        chains = tag_breadcrumb_chains(art).map { |c| c.map(&:name) }
        expect(chains).to eq([ [ 'Triathlon', 'Half Distance', 'Ironman 70.3 Coeur d’Alene' ], [ 'Race Reports' ] ])
      end

      it 'renders multiple chains within a scheme (Sports before Topics on a depth tie)' do
        art = tagged_article(slug: 'rev', concepts: [
          concept('running', 'Running', path: '/tagged/running/', scheme: 'sports'),
          concept('tech', 'Tech', path: '/tagged/tech/', scheme: 'topics'),
          concept('gear', 'Gear', path: '/tagged/tech/gear/', parent_id: 'tech', scheme: 'topics'),
          concept('reviews', 'Reviews', path: '/tagged/reviews/', scheme: 'topics')
        ])
        chains = tag_breadcrumb_chains(art).map { |c| c.map(&:name) }
        expect(chains).to eq([ [ 'Tech', 'Gear' ], [ 'Running' ], [ 'Reviews' ] ])
      end

      it 'follows the full taxonomy to the root, omitting unassigned intermediates (e.g. "Other")' do
        # The article has the race and the discipline, but NOT the "Other" group between them.
        art = tagged_article(slug: 'alcatraz', concepts: [
          concept('triathlon', 'Triathlon', path: '/tagged/triathlon/', scheme: 'sports'),
          concept('escape-from-alcatraz-triathlon', 'Escape from Alcatraz Triathlon', short_name: 'Escape from Alcatraz',
                  path: '/tagged/triathlon/triathlon-other/escape-from-alcatraz-triathlon/', parent_id: 'triathlon-other', scheme: 'sports'),
          race_reports
        ])
        chains = tag_breadcrumb_chains(art).map { |c| c.map(&:short_name) }
        expect(chains).to eq([ [ 'Triathlon', 'Escape from Alcatraz' ], [ 'Race Reports' ] ])
      end

      it 'is empty when the article has no taxonomy' do
        expect(tag_breadcrumb_chains(article(slug: 'x'))).to eq([])
      end
    end

    describe '#concept_chain' do
      it 'resolves the root-first, inclusive ancestor chain from data.tags' do
        expect(concept_chain('ironman-703-coeur-dalene')).to eq([
          { id: 'triathlon', name: 'Triathlon', path: '/tagged/triathlon/' },
          { id: 'half-distance', name: 'Half Distance', path: '/tagged/triathlon/half-distance/' },
          { id: 'ironman-703-coeur-dalene', name: 'Ironman 70.3 Coeur d’Alene', path: '/tagged/triathlon/half-distance/ironman-703-coeur-dalene/' }
        ])
      end

      it 'is a single-node chain for a root concept' do
        expect(concept_chain('triathlon')).to eq([ { id: 'triathlon', name: 'Triathlon', path: '/tagged/triathlon/' } ])
      end

      it 'is empty for an unknown concept id' do
        expect(concept_chain('nope')).to eq([])
      end

      context 'when parents form a cycle' do
        def data
          OpenStruct.new(tags: [
            OpenStruct.new(tag: OpenStruct.new(id: 'a', name: 'A', path: '/tagged/a/', parent_id: 'b', scheme: 'topics', entry_count: 1)),
            OpenStruct.new(tag: OpenStruct.new(id: 'b', name: 'B', path: '/tagged/b/', parent_id: 'a', scheme: 'topics', entry_count: 1))
          ])
        end

        it 'stops at the first repeated concept instead of looping' do
          expect(concept_chain('a').map { |n| n[:id] }).to eq(%w[b a])
        end
      end
    end

    describe '#taxonomy_index' do
      it 'indexes each concept by id with its name, path, parent, scheme, and archive count' do
        expect(taxonomy_index['half-distance']).to eq(
          name: 'Half Distance', path: '/tagged/triathlon/half-distance/', parent_id: 'triathlon', scheme: 'sports', count: 10
        )
        expect(taxonomy_index['race-reports']).to eq(
          name: 'Race Reports', path: '/tagged/race-reports/', parent_id: nil, scheme: 'topics', count: 12
        )
      end

      it 'memoizes the index within a render context' do
        expect(taxonomy_index).to equal(taxonomy_index)
      end
    end
  end
end
