# The doubles that the specs of the entry helpers share: an article, and the `data.articles`
# that holds it.
RSpec.shared_context 'article doubles' do
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

  # Middleman supplies `data` at run time. This file defines it as a true method, because a
  # verifying double refuses a stub of a method that this object does not have.
  def data
    OpenStruct.new(articles: @corpus || [])
  end
end

# The larger doubles for a helper that reads the taxonomy. Such a helper needs tags with path and
# parent_id, and not only id and name, and it needs a data.tags tree. Thus `data` here replaces
# the one of 'article doubles'.
RSpec.shared_context 'a taxonomy' do
  include_context 'article doubles'

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

  # The same tree as the tag pages that the build makes: Sports (Triathlon › Half Distance › one
  # race) and Topics (Race Reports, News, Reviews, and Tech › Gear). Each concept has its scheme
  # and its archive count.
  def taxonomy_tags
    [
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
      concept('gear', 'Gear', path: '/tagged/tech/gear/', parent_id: 'tech', scheme: 'topics', count: 3),
      concept('apps', 'Apps', path: '/tagged/tech/apps/', parent_id: 'tech', scheme: 'topics', count: 4),
      concept('trainerroad', 'TrainerRoad', path: '/tagged/tech/apps/trainerroad/', parent_id: 'apps', scheme: 'topics', count: 2),
      concept('zwift', 'Zwift', path: '/tagged/tech/apps/zwift/', parent_id: 'apps', scheme: 'topics', count: 2)
    ].map { |c| OpenStruct.new(tag: c) }
  end

  def data
    OpenStruct.new(articles: @corpus || [], tags: taxonomy_tags)
  end
end
