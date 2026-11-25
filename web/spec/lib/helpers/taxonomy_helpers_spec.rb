require 'spec_helper'

RSpec.describe TaxonomyHelpers do
  include_context 'default helper stubs'
  include_context 'article doubles'

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
      it 'renders slash-separated listitem links' do
        html = tag_chain_links([ [ 'Triathlon', '/tagged/triathlon/' ], [ 'Half Distance', '/tagged/triathlon/half-distance/' ], [ 'Race Reports', '/tagged/race-reports/' ] ])
        separator = '<span class="entry__tag-separator" aria-hidden="true">/</span>'
        expect(html).to eq(
          '<span role="listitem"><a href="/tagged/triathlon/">Triathlon</a></span>' + separator +
          '<span role="listitem"><a href="/tagged/triathlon/half-distance/">Half Distance</a></span>' + separator +
          '<span role="listitem"><a href="/tagged/race-reports/">Race Reports</a></span>'
        )
      end
    end
  end

  describe '#taxonomy_trail' do
    include_context 'a taxonomy'

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

  describe '#tag_breadcrumb_chains' do
    include_context 'a taxonomy'

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

    it 'skips a concept that has no tag page, and does not raise' do
      # A concept with no published article gets no page, thus data.tags has no entry for it. A
      # draft can hold such a concept.
      art = tagged_article(slug: 'rouvy', concepts: [
        concept('tech', 'Tech', path: '/tagged/tech/', scheme: 'topics'),
        concept('apps', 'Apps', path: '/tagged/tech/apps/', parent_id: 'tech', scheme: 'topics'),
        concept('rouvy', 'Rouvy', path: '/tagged/tech/apps/rouvy/', parent_id: 'apps', scheme: 'topics'),
        concept('running', 'Running', path: '/tagged/running/', scheme: 'sports')
      ])
      chains = tag_breadcrumb_chains(art).map { |c| c.map(&:name) }
      expect(chains).to eq([ [ 'Tech', 'Apps' ], [ 'Running' ] ])
    end

    it 'is empty when every concept of the article has no tag page' do
      art = tagged_article(slug: 'unknown', concepts: [
        concept('rouvy', 'Rouvy', path: '/tagged/tech/apps/rouvy/', parent_id: 'apps', scheme: 'topics')
      ])
      expect(tag_breadcrumb_chains(art)).to eq([])
    end

    it 'is empty when the article has no taxonomy' do
      expect(tag_breadcrumb_chains(article(slug: 'x'))).to eq([])
    end
  end

  describe '#tag_breadcrumb_concepts' do
    include_context 'a taxonomy'

    it 'gives a shared parent one time and keeps its children together' do
      art = tagged_article(slug: 'tr-zwift', concepts: [
        concept('tech', 'Tech', path: '/tagged/tech/', scheme: 'topics'),
        concept('apps', 'Apps', path: '/tagged/tech/apps/', parent_id: 'tech', scheme: 'topics'),
        concept('trainerroad', 'TrainerRoad', path: '/tagged/tech/apps/trainerroad/', parent_id: 'apps', scheme: 'topics'),
        concept('zwift', 'Zwift', path: '/tagged/tech/apps/zwift/', parent_id: 'apps', scheme: 'topics'),
        concept('running', 'Running', path: '/tagged/running/', scheme: 'sports'),
        concept('news', 'News', path: '/tagged/news/', scheme: 'topics')
      ])
      expect(tag_breadcrumb_concepts(art).map(&:name)).to eq([ 'Tech', 'Apps', 'TrainerRoad', 'Zwift', 'Running', 'News' ])
    end

    it 'keeps the branches of a shared root together' do
      art = tagged_article(slug: 'branches', concepts: [
        concept('tech', 'Tech', path: '/tagged/tech/', scheme: 'topics'),
        concept('apps', 'Apps', path: '/tagged/tech/apps/', parent_id: 'tech', scheme: 'topics'),
        concept('zwift', 'Zwift', path: '/tagged/tech/apps/zwift/', parent_id: 'apps', scheme: 'topics'),
        concept('gear', 'Gear', path: '/tagged/tech/gear/', parent_id: 'tech', scheme: 'topics'),
        concept('running', 'Running', path: '/tagged/running/', scheme: 'sports')
      ])
      expect(tag_breadcrumb_concepts(art).map(&:name)).to eq([ 'Tech', 'Apps', 'Zwift', 'Gear', 'Running' ])
    end

    it 'gives every concept of the article one time' do
      art = tagged_article(slug: 'tr-zwift', concepts: [
        concept('tech', 'Tech', path: '/tagged/tech/', scheme: 'topics'),
        concept('apps', 'Apps', path: '/tagged/tech/apps/', parent_id: 'tech', scheme: 'topics'),
        concept('trainerroad', 'TrainerRoad', path: '/tagged/tech/apps/trainerroad/', parent_id: 'apps', scheme: 'topics'),
        concept('zwift', 'Zwift', path: '/tagged/tech/apps/zwift/', parent_id: 'apps', scheme: 'topics')
      ])
      names = tag_breadcrumb_concepts(art).map(&:name)
      expect(names.uniq).to eq(names)
      expect(names.size).to eq(4)
    end

    it 'omits a concept that has no tag page' do
      art = tagged_article(slug: 'rouvy', concepts: [
        concept('tech', 'Tech', path: '/tagged/tech/', scheme: 'topics'),
        concept('apps', 'Apps', path: '/tagged/tech/apps/', parent_id: 'tech', scheme: 'topics'),
        concept('trainerroad', 'TrainerRoad', path: '/tagged/tech/apps/trainerroad/', parent_id: 'apps', scheme: 'topics'),
        concept('rouvy', 'Rouvy', path: '/tagged/tech/apps/rouvy/', parent_id: 'apps', scheme: 'topics')
      ])
      expect(tag_breadcrumb_concepts(art).map(&:name)).to eq([ 'Tech', 'Apps', 'TrainerRoad' ])
    end

    it 'is empty when the article has no taxonomy' do
      expect(tag_breadcrumb_concepts(article(slug: 'x'))).to eq([])
    end
  end

  describe '#concept_chain' do
    include_context 'a taxonomy'

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
    include_context 'a taxonomy'

    it 'indexes each concept by id with its name, path, parent, scheme, and archive count' do
      expect(taxonomy_index['half-distance']).to eq(
        name: 'Half Distance', path: '/tagged/triathlon/half-distance/', parent_id: 'triathlon', scheme: 'sports', count: 10
      )
      expect(taxonomy_index['race-reports']).to eq(
        name: 'Race Reports', path: '/tagged/race-reports/', parent_id: nil, scheme: 'topics', count: 12
      )
    end

    it 'memoizes the index for one tags collection' do
      same = data
      allow(self).to receive(:data).and_return(same)

      expect(taxonomy_index).to equal(taxonomy_index)
    end
  end
end
