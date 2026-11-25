require 'spec_helper'

RSpec.describe RecirculationHelpers do
  include_context 'default helper stubs'
  include_context 'article doubles'

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

  # The section of a Short: the related entries without the two adjacent entries, which the
  # read-next section already shows, and without the entry itself.
  describe '#related_section' do
    def data
      OpenStruct.new(articles: @corpus || [], related: @related || {})
    end

    def entry(slug, id, published_at)
      a = article(slug: slug, published_at: published_at)
      a.sys = OpenStruct.new(id: id)
      a
    end

    let(:newer) { entry('newer', 'id-newer', '2024-04-01T00:00:00Z') }
    let(:short) { entry('short', 'id-a', '2024-03-01T00:00:00Z') }
    let(:older) { entry('older', 'id-older', '2024-02-01T00:00:00Z') }
    let(:other) { entry('other', 'id-o', '2024-01-01T00:00:00Z') }

    before { stub_corpus([ newer, short, older, other ]) }

    it 'removes the adjacent entries and the entry itself, and fills the section from the rest' do
      @related = { 'id-a' => %w[id-older id-a id-newer id-o] }
      expect(related_section(short).map(&:slug)).to eq([ 'other' ])
    end

    it 'keeps the order of the api' do
      @related = { 'id-a' => %w[id-o id-older] }
      expect(related_section(short, count: 1).map(&:slug)).to eq([ 'other' ])
    end

    it 'returns nothing when the entry has no neighbor' do
      @related = {}
      expect(related_section(short)).to eq([])
    end
  end

  describe '#race_concept_id / #related_race_reports' do
    include_context 'a taxonomy'

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
    include_context 'a taxonomy'

    # This group needs data.related as well as data.articles and data.tags.
    def data
      OpenStruct.new(articles: @corpus || [], tags: taxonomy_tags, related: @related || {})
    end

    # A tagged article that also has a sys id, thus data.related can name it.
    def entry(slug, id, concepts: [], **opts)
      a = tagged_article(slug: slug, concepts: concepts, **opts)
      a.sys = OpenStruct.new(id: id)
      a
    end

    # ⚠️ The two sections must not exclude each other. This article then shows its five cards, and
    # not one card.
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
      a = entry('post', 'id-a', published_at: '2024-03-01T00:00:00Z')
      adjacent = entry('adjacent', 'id-adj', published_at: '2024-02-01T00:00:00Z')
      other = entry('other', 'id-o', published_at: '2024-01-01T00:00:00Z')
      stub_corpus([ a, adjacent, other ])
      @related = { 'id-a' => [ 'id-o' ] }

      sections = recirculation_sections(a)
      expect(sections[:reports]).to eq([])
      expect(sections[:related].map(&:slug)).to eq([ 'other' ])
    end

    # ⚠️ The read-next section renders the two adjacent entries on the same page, and an entry
    # with a near meaning is frequently also the adjacent one.
    it 'never lists an adjacent entry, which the read-next section already shows' do
      newer = entry('newer', 'id-newer', published_at: '2024-04-01T00:00:00Z')
      a = entry('post', 'id-a', published_at: '2024-03-01T00:00:00Z')
      older = entry('older', 'id-older', published_at: '2024-02-01T00:00:00Z')
      other = entry('other', 'id-o', published_at: '2024-01-01T00:00:00Z')
      stub_corpus([ newer, a, older, other ])
      @related = { 'id-a' => %w[id-older id-newer id-o] }

      expect(recirculation_sections(a)[:related].map(&:slug)).to eq([ 'other' ])
    end

    # Two empty lists render no section at all.
    it 'is empty when the article has no neighbor' do
      a = entry('lonely', 'id-a')
      stub_corpus([ a ])

      expect(recirculation_sections(a)).to eq({ reports: [], related: [] })
    end
  end
end
