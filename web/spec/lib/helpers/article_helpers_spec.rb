require 'spec_helper'
require 'ostruct'

# RSpec auto-includes the described module, so ArticleHelpers' instance methods are callable directly.
RSpec.describe ArticleHelpers do
  # Builds an article double shaped like a `data.articles` entry (dot-access, nested tags/event).
  def article(slug:, title: 'Title', tags: [], published_at: '2024-01-01T10:00:00Z',
              entry_type: 'Article', draft: false, event_id: nil)
    OpenStruct.new(
      slug: slug,
      path: "/#{slug}/",
      title: title,
      published_at: published_at,
      entry_type: entry_type,
      draft: draft,
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

  describe '#similarity_score (IDF-weighted Jaccard tags)' do
    it 'weights a shared rare tag above a shared common tag' do
      # 'triathlon' is on nearly everything (common); 'vo2max' is on almost nothing (rare).
      corpus = [
        article(slug: 'ref',    tags: %w[triathlon vo2max]),
        article(slug: 'rare',   tags: %w[vo2max]),
        article(slug: 'common', tags: %w[triathlon]),
        *5.times.map { |i| article(slug: "filler#{i}", tags: %w[triathlon]) }
      ]
      stub_corpus(corpus)
      ref, rare, common = corpus[0], corpus[1], corpus[2]

      expect(similarity_score(ref, rare)).to be > similarity_score(ref, common)
    end

    it 'penalizes a candidate padded with many unrelated tags (symmetric union)' do
      corpus = [
        article(slug: 'ref',   tags: %w[swim bike run]),
        article(slug: 'exact', tags: %w[swim bike run]),
        article(slug: 'noisy', tags: %w[swim bike run cooking travel music photography baking]),
        article(slug: 'other', tags: %w[cooking travel])
      ]
      stub_corpus(corpus)
      ref, exact, noisy = corpus[0], corpus[1], corpus[2]

      # Same shared tags, but the noisy candidate's extra tags enlarge the union → lower Jaccard.
      expect(similarity_score(ref, exact)).to be > similarity_score(ref, noisy)
    end

    it 'scores zero similarity between articles that share no tags or title words' do
      corpus = [article(slug: 'ref', title: 'Alpha', tags: %w[swim]),
                article(slug: 'unrelated', title: 'Omega', tags: %w[cooking])]
      stub_corpus(corpus)
      expect(similarity_score(corpus[0], corpus[1])).to eq(0.0)
    end
  end

  describe '#normalize_title' do
    it 'drops stopwords, punctuation, and case so shared filler does not inflate title similarity' do
      expect(normalize_title('The Race to My Cabin!')).to eq('race cabin')
    end

    it 'gives two titles overlapping only on stopwords a low similarity' do
      corpus = [article(slug: 'a', title: 'The Best of My Year', tags: []),
                article(slug: 'b', title: 'The Worst of My Day', tags: [])]
      stub_corpus(corpus)
      # No shared tags; "the/of/my" are stripped, so only best/year vs worst/day remain → low.
      expect(similarity_score(corpus[0], corpus[1])).to be < 0.2
    end
  end

  describe '#related_articles' do
    let(:ref) { article(slug: 'ref', title: 'Marathon Training', tags: %w[running marathon], event_id: 'evt1') }

    it 'excludes the article itself, drafts, and Shorts' do
      corpus = [
        ref,
        article(slug: 'draft', tags: %w[running marathon], draft: true),
        article(slug: 'short', tags: %w[running marathon], entry_type: 'Short'),
        article(slug: 'ok',    tags: %w[running marathon])
      ]
      stub_corpus(corpus)
      slugs = related_articles(ref).map(&:slug)
      expect(slugs).to eq(%w[ok])
      expect(slugs).not_to include('ref', 'draft', 'short')
    end

    it 'excludes race reports from the same event (shown in their own section)' do
      corpus = [
        ref,
        article(slug: 'race-report', tags: %w[running marathon], event_id: 'evt1'),
        article(slug: 'plain',       tags: %w[running marathon])
      ]
      stub_corpus(corpus)
      expect(related_articles(ref).map(&:slug)).to eq(%w[plain])
    end

    it 'ranks by similarity, breaking ties toward the newer article' do
      corpus = [
        ref,
        article(slug: 'older-match', tags: %w[running marathon], published_at: '2020-01-01T00:00:00Z'),
        article(slug: 'newer-match', tags: %w[running marathon], published_at: '2024-01-01T00:00:00Z'),
        article(slug: 'weak',        tags: %w[running])
      ]
      stub_corpus(corpus)
      slugs = related_articles(ref).map(&:slug)
      expect(slugs.first(2)).to eq(%w[newer-match older-match]) # equal similarity → newer first
      expect(slugs.last).to eq('weak')                          # fewer shared tags → ranked lower
    end

    it 'returns at most the requested count' do
      corpus = [ref] + 10.times.map { |i| article(slug: "a#{i}", tags: %w[running marathon]) }
      stub_corpus(corpus)
      expect(related_articles(ref, count: 4).size).to eq(4)
    end
  end
end
