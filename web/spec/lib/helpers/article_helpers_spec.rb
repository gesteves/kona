require 'spec_helper'
require 'ostruct'
require 'padrino-helpers'

# RSpec auto-includes the described module, so ArticleHelpers' instance methods are callable directly.
RSpec.describe ArticleHelpers do
  # Builds an article double shaped like a `data.articles` entry (dot-access, nested tags/event).
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

  # Sets the corpus returned by `data.articles`.
  def stub_corpus(articles)
    @corpus = articles
  end

  # The helper depends on these collaborators (normally mixed in from other modules); define them
  # directly so verifying-doubles doesn't reject stubbing methods this object doesn't implement.
  def data
    OpenStruct.new(articles: @corpus || [])
  end

  # Passthrough sanitize — the real one runs the markdown pipeline, which these scorers don't need.
  def sanitize(text, **)
    text
  end

  describe '#adjacent_articles' do
    # data.articles arrives sorted newest-first, so index-1 is newer and index+1 is older.
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
      # The draft is dropped from the sequence, so 'newest' sits next to the Short.
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
      # data.articles is already sorted newest-first upstream, so the helper preserves input order.
      expect(llms_articles.map(&:slug)).to eq(%w[keep-new keep-old])
    end

    it 'caps the list at the requested count' do
      stub_corpus(12.times.map { |i| article(slug: "a#{i}") })
      expect(llms_articles(count: 5).size).to eq(5)
    end
  end

  describe '#article_schema' do
    # Collaborators that live in other helper modules at runtime; stubbed here so the schema builder
    # is exercised in isolation.
    def content_summary(content) = content.summary
    def canonical_url = 'https://example.com/2024/01/01/post/'
    def schema_entity_id(fragment, path: '/') = "https://example.com#{path == '/' ? '/' : "#{path}/"}##{fragment}"
    def cdn_image_url(url, params = {}) = "#{url}?w=#{params[:w]}&h=#{params[:h]}"
    def full_url(path) = "https://example.com#{path}"
    def generate_open_graph_image_url(url) = "https://example.com/og?url=#{url}"
    def current_page = OpenStruct.new(url: '/2024/01/01/post/')

    def schema_article(**overrides)
      cover_image = overrides.delete(:cover_image)
      defaults = {
        slug: 'post', title: 'A Post', summary: 'A summary.', draft: false,
        intro: 'one two three four', body: 'five six',
        published_at: '2024-01-01T10:00:00Z', tags: %w[running marathon]
      }
      a = article(**defaults.merge(overrides))
      a.sys = OpenStruct.new(published_at: '2024-02-01T10:00:00Z')
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
        OpenStruct.new(name: 'Ironman 70.3', synonyms: ['Half Ironman', '70.3']),
        OpenStruct.new(name: 'Race Reports', synonyms: [])
      ])
      schema = JSON.parse(article_schema(a))
      expect(schema['keywords']).to eq(['Ironman 70.3', 'Half Ironman', '70.3', 'Race Reports'])
      expect(schema['articleSection']).to eq('Ironman 70.3')
    end

    it 'emits cover images as ImageObjects with dimensions' do
      cover = OpenStruct.new(url: '//images/cover.jpg')
      schema = JSON.parse(article_schema(schema_article(cover_image: cover)))
      expect(schema['image']).to all(include('@type' => 'ImageObject'))
      expect(schema['image'].map { |i| [i['width'], i['height']] })
        .to eq([[1000, 1000], [1600, 900], [1600, 1200]])
    end

    it 'falls back to the generated Open Graph card when there is no cover image (e.g. a Short)' do
      schema = JSON.parse(article_schema(schema_article(cover_image: nil)))
      expect(schema['image']).to eq([{
        '@type' => 'ImageObject',
        'url' => 'https://example.com/og?url=https://example.com/2024/01/01/post/',
        'width' => 1200,
        'height' => 630
      }])
    end
  end

  describe '#breadcrumb_schema' do
    def full_url(path) = "https://example.com#{path}"
    def canonical_url = 'https://example.com/2024/01/01/post/'

    it 'builds a Home > Blog > title breadcrumb for both articles and shorts' do
      %w[Article Short].each do |type|
        schema = JSON.parse(breadcrumb_schema(article(slug: 'post', title: 'A Post', entry_type: type)))
        expect(schema['@type']).to eq('BreadcrumbList')
        expect(schema['itemListElement'].map { |i| i['name'] }).to eq(%w[Home Blog] + ['A Post'])
      end
    end

    it 'returns nil for drafts and for non-article/short entries' do
      expect(breadcrumb_schema(article(slug: 'draft', draft: true))).to be_nil
      expect(breadcrumb_schema(article(slug: 'about', entry_type: 'Page'))).to be_nil
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
  end

  # The taxonomy-aware helpers need tags carrying path/parent_id (not just id/name) and a
  # data.tags hierarchy, so this group defines richer builders that override the outer ones.
  describe 'taxonomy-aware helpers' do
    def full_url(path) = "https://example.com#{path}"
    def canonical_url = 'https://example.com/2024/01/01/post/'

    # A concept "tag" as it appears on an article after taxonomy normalization.
    def concept(id, name, path:, parent_id: nil)
      OpenStruct.new(id: id, name: name, path: path, parent_id: parent_id)
    end

    # An article whose contentful_metadata.tags are full concept doubles.
    def tagged_article(slug:, concepts:, **opts)
      a = article(slug: slug, **opts)
      a.contentful_metadata = OpenStruct.new(tags: concepts)
      a
    end

    # data.tags mirrors the generated tag pages: one { tag: <concept> } per concept, so the
    # breadcrumb trail can resolve ancestors. Includes the topic hierarchy + a races branch.
    def data
      tags = [
        concept('triathlon', 'Triathlon', path: '/tagged/triathlon/'),
        concept('ironman-703', 'Ironman 70.3', path: '/tagged/triathlon/ironman-703/', parent_id: 'triathlon'),
        concept('race-reports', 'Race Reports', path: '/tagged/race-reports/'),
        concept('running', 'Running', path: '/tagged/running/'),
        concept('races', 'Races', path: '/tagged/races/'),
        concept('ironman-703-coeur-dalene', 'Ironman 70.3 Coeur d’Alene', path: '/tagged/races/ironman-703-coeur-dalene/', parent_id: 'races')
      ].map { |c| OpenStruct.new(tag: c) }
      OpenStruct.new(articles: @corpus || [], tags: tags)
    end

    describe '#taxonomy_trail' do
      it 'returns the deepest topic chain, excluding the races branch' do
        art = tagged_article(slug: 'cda', concepts: [
          concept('ironman-703', 'Ironman 70.3', path: '/tagged/triathlon/ironman-703', parent_id: 'triathlon'),
          concept('race-reports', 'Race Reports', path: '/tagged/race-reports'),
          concept('ironman-703-coeur-dalene', 'Ironman 70.3 Coeur d’Alene', path: '/tagged/races/ironman-703-coeur-dalene', parent_id: 'races')
        ])
        expect(taxonomy_trail(art).map { |n| n[:name] }).to eq(['Triathlon', 'Ironman 70.3'])
      end

      it 'is empty when the article has no taxonomy' do
        expect(taxonomy_trail(article(slug: 'x'))).to eq([])
      end
    end

    describe '#breadcrumb_schema with a taxonomy trail' do
      it 'inserts the topic trail between Blog and the article, numbered in order' do
        art = tagged_article(slug: 'post', title: 'A Post', concepts: [
          concept('ironman-703', 'Ironman 70.3', path: '/tagged/triathlon/ironman-703', parent_id: 'triathlon')
        ])
        schema = JSON.parse(breadcrumb_schema(art))
        expect(schema['itemListElement'].map { |i| i['name'] }).to eq(['Home', 'Blog', 'Triathlon', 'Ironman 70.3', 'A Post'])
        expect(schema['itemListElement'].map { |i| i['position'] }).to eq([1, 2, 3, 4, 5])
        expect(schema['itemListElement'][2]['item']).to eq('https://example.com/tagged/triathlon/')
      end
    end

    describe '#race_concept_id / #related_race_reports' do
      it 'reads the concept under the races branch' do
        art = tagged_article(slug: 'cda-2025', concepts: [
          concept('ironman-703-coeur-dalene', 'Ironman 70.3 Coeur d’Alene', path: '/tagged/races/ironman-703-coeur-dalene', parent_id: 'races')
        ])
        expect(race_concept_id(art)).to eq('ironman-703-coeur-dalene')
        expect(race_concept_id(article(slug: 'no-race', tags: %w[triathlon]))).to be_nil
      end

      it 'groups race reports by their shared races concept, excluding non-reports and Shorts' do
        race = concept('ironman-703-coeur-dalene', 'Ironman 70.3 Coeur d’Alene', path: '/tagged/races/ironman-703-coeur-dalene', parent_id: 'races')
        rr = concept('race-reports', 'Race Reports', path: '/tagged/race-reports')
        a2025 = tagged_article(slug: 'cda-2025', concepts: [rr, race], published_at: '2025-06-01T00:00:00Z')
        a2024 = tagged_article(slug: 'cda-2024', concepts: [rr, race], published_at: '2024-06-01T00:00:00Z')
        short = tagged_article(slug: 'cda-short', concepts: [rr, race], entry_type: 'Short', published_at: '2023-06-01T00:00:00Z')
        preview = tagged_article(slug: 'cda-preview', concepts: [race], published_at: '2023-01-01T00:00:00Z') # same race, but not a report
        other = tagged_article(slug: 'other', concepts: [concept('running', 'Running', path: '/tagged/running')], published_at: '2025-01-01T00:00:00Z')
        stub_corpus([a2025, a2024, short, preview, other])

        expect(related_race_reports(a2025).map(&:slug)).to eq(['cda-2024'])
      end

      it 'returns nothing when the article has no race concept' do
        stub_corpus([tagged_article(slug: 'solo', concepts: [concept('running', 'Running', path: '/tagged/running')])])
        expect(related_race_reports(article(slug: 'solo'))).to eq([])
      end
    end
  end
end
