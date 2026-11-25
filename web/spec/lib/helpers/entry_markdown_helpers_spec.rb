require 'spec_helper'
require 'yaml'

RSpec.describe EntryMarkdownHelpers do
  include_context 'default helper stubs'

  def entry(**attrs)
    OpenStruct.new(title: 'A Race', path: '/2024/01/01/a-race/index.html', published_at: '2024-01-01T08:30:00-07:00',
                   summary: 'Hi', intro: 'Intro.', body: 'Body.', **attrs)
  end

  before do
    allow(self).to receive(:render_markdown_body) { |text, **| text }
    allow(self).to receive(:show_affiliate_links_disclosure?).and_return(false)
  end

  describe '.markdown_path' do
    it 'puts index.md in the place of index.html' do
      expect(described_class.markdown_path('/2024/01/01/a-race/index.html')).to eq('/2024/01/01/a-race/index.md')
    end
  end

  describe '#entry_markdown_path' do
    it 'gives the path of the Markdown document of the entry' do
      expect(entry_markdown_path(entry)).to eq('/2024/01/01/a-race/index.md')
    end
  end

  describe '#entry_markdown' do
    # ⚠️ The front matter must start the file, and a summary can hold YAML syntax.
    it 'starts with front matter, then the title, the intro, and the body' do
      summary = 'Swim: “bike, run” # and more'
      document = entry_markdown(entry(summary: summary))

      expect(document).to start_with("---\ntitle: ")
      _, front_matter, body = document.split(/^---\n/, 3)
      expect(YAML.safe_load(front_matter)).to eq(
        'title' => 'A Race',
        'url' => 'https://example.com/2024/01/01/a-race/',
        'published' => '2024-01-01T08:30:00-07:00',
        'summary' => summary
      )
      expect(body).to eq("\n# A Race\n\nIntro.\n\nBody.\n")
    end

    it 'resolves the links of the intro and the body against the URL of the post' do
      entry_markdown(entry)

      expect(self).to have_received(:render_markdown_body).with('Intro.', base_url: 'https://example.com/2024/01/01/a-race/')
      expect(self).to have_received(:render_markdown_body).with('Body.', base_url: 'https://example.com/2024/01/01/a-race/')
    end

    it 'has no summary in the front matter when the entry has none' do
      _, front_matter, = entry_markdown(entry(summary: nil)).split(/^---\n/, 3)

      expect(YAML.safe_load(front_matter)).not_to have_key('summary')
    end

    it 'gives the intro only for a Short' do
      expect(entry_markdown(entry(body: nil))).to end_with("# A Race\n\nIntro.\n")
    end

    it 'adds the affiliate disclosure when the entry needs one' do
      allow(self).to receive(:show_affiliate_links_disclosure?).and_return(true)
      allow(self).to receive(:affiliate_links_disclosure).and_return('<p>Affiliate links.</p>')

      expect(entry_markdown(entry)).to end_with("Body.\n\nAffiliate links.\n")
    end
  end
end
