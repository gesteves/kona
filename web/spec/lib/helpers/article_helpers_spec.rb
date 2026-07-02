require 'spec_helper'
require 'ostruct'

# RSpec auto-includes the described module, so ArticleHelpers' instance methods are callable directly.
RSpec.describe ArticleHelpers do
  # Builds an article double shaped like a `data.articles` entry (dot-access, nested tags/event).
  def article(slug:, title: 'Title', tags: [], published_at: '2024-01-01T10:00:00Z',
              entry_type: 'Article', draft: false, event_id: nil, index_in_search_engines: true,
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
      event: event_id && OpenStruct.new(sys: OpenStruct.new(id: event_id)),
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

    it 'omits keywords and image when the article has none' do
      schema = JSON.parse(article_schema(schema_article(tags: [])))
      expect(schema).not_to have_key('keywords')
      expect(schema).not_to have_key('articleSection')
      expect(schema).not_to have_key('image')
    end

    it 'emits cover images as ImageObjects with dimensions' do
      cover = OpenStruct.new(url: '//images/cover.jpg')
      schema = JSON.parse(article_schema(schema_article(cover_image: cover)))
      expect(schema['image']).to all(include('@type' => 'ImageObject'))
      expect(schema['image'].map { |i| [i['width'], i['height']] })
        .to eq([[1000, 1000], [1600, 900], [1600, 1200]])
    end
  end
end
