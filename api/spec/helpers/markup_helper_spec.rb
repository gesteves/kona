require "rails_helper"

RSpec.describe MarkupHelper do
  subject(:helper) do
    Class.new do
      include ActionView::Helpers::TagHelper
      include MarkdownHelper
      include MarkupHelper
    end.new
  end

  describe "#units_tag" do
    it "renders the unit-conversion span" do
      result = helper.units_tag("10 km", "6.2 mi")
      expect(result).to include('data-controller="units"')
      expect(result).to include('data-units-metric-value="10 km"')
      expect(result).to include('data-units-imperial-value="6.2 mi"')
      expect(result).to include(">10 km<")
    end
  end

  describe "#render_summary_body" do
    it "renders Markdown prose" do
      expect(helper.render_summary_body("Hello **world**.")).to eq("<p>Hello <strong>world</strong>.</p>\n")
    end

    it "opens external links in a new tab" do
      result = helper.render_summary_body("See [the site](https://example.com).")
      expect(result).to include('target="_blank"')
      expect(result).to include('rel="noopener"')
    end

    it "converts inline unit spans into the metric/imperial toggle" do
      result = helper.render_summary_body('Run <span data-imperial="6.2 mi">10 km</span> today.')
      expect(result).to include('data-units-metric-value="10 km"')
      expect(result).to include('data-units-imperial-value="6.2 mi"')
    end

    it "returns nil for blank input" do
      expect(helper.render_summary_body(nil)).to be_nil
      expect(helper.render_summary_body("")).to be_nil
    end
  end
end
