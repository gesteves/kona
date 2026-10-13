require 'spec_helper'
require 'ostruct'
require 'yaml'

RSpec.describe AboutHelpers do
  include_context 'default helper stubs'

  def page(**attrs)
    OpenStruct.new(slug: 'about', draft: false, path: '/about/index.html', summary: 'Hi', body: 'Body.', **attrs)
  end

  before do
    allow(self).to receive(:render_markdown_body).and_return('Body.')
    allow(self).to receive(:show_affiliate_links_disclosure?).and_return(false)
  end

  describe '.about_page' do
    it 'finds the published page with the about slug' do
      about = page
      pages = [ page(slug: 'contact'), page(draft: true), about ]

      expect(described_class.about_page(pages)).to be(about)
      expect(described_class.about_page([ page(draft: true) ])).to be_nil
    end
  end

  describe '#about_markdown' do
    # ⚠️ The front matter must start the file, and a summary can hold YAML syntax.
    it 'starts with front matter that holds the summary, then the body' do
      summary = 'Triathlete: “swim, bike, run” # and more'
      document = about_markdown(page(summary: summary))

      expect(document).to start_with("---\nsummary: ")
      _, front_matter, body = document.split(/^---\n/, 3)
      expect(YAML.safe_load(front_matter)).to eq('summary' => summary)
      expect(body).to eq("\nBody.\n")
    end

    it 'resolves the links of the body against the URL of the page' do
      about_markdown(page)

      expect(self).to have_received(:render_markdown_body).with('Body.', base_url: 'https://example.com/about/')
    end

    it 'has no front matter when the page has no summary' do
      expect(about_markdown(page(summary: nil))).to eq("Body.\n")
    end

    it 'adds the affiliate disclosure when the page needs one' do
      allow(self).to receive(:show_affiliate_links_disclosure?).and_return(true)
      allow(self).to receive(:affiliate_links_disclosure).and_return('<p>Affiliate links.</p>')

      expect(about_markdown(page(summary: nil))).to eq("Body.\n\nAffiliate links.\n")
    end
  end
end
