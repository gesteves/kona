require "rails_helper"

RSpec.describe MarkupHelper do
  subject(:helper) do
    Class.new do
      include ActionView::Helpers::TagHelper
      include MarkdownHelper
      include TextHelper
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

    # The same summary text renders on the article page, from the static build, and in the trending
    # or related widget fragment. The disclosure must stay in both.
    describe "affiliate links" do
      it "marks an Amazon Associates link as sponsored" do
        result = helper.render_summary_body("Bought [these](https://www.amazon.com/dp/B01?tag=kona-20).")
        expect(result).to include('rel="sponsored nofollow noopener"')
        expect(result).to include('target="_blank"')
      end

      it "marks an amzn.to short link as sponsored" do
        result = helper.render_summary_body("Bought [these](https://amzn.to/3abcdef).")
        expect(result).to include('rel="sponsored nofollow noopener"')
      end

      it "leaves a tagless amazon.com link as an ordinary external link" do
        result = helper.render_summary_body("Read [this](https://www.amazon.com/dp/B01).")
        expect(result).to include('rel="noopener"')
        expect(result).not_to include("sponsored")
      end

      it "does not treat a lookalike host as Amazon" do
        result = helper.render_summary_body("See [this](https://notamazon.com/dp/B01?tag=x).")
        expect(result).not_to include("sponsored")
      end

      it "ignores a malformed href rather than raising" do
        expect { helper.render_summary_body("[bad](http://[)") }.not_to raise_error
      end
    end

    it "normalizes the masculine ordinal into a degree sign" do
      expect(helper.render_summary_body("It hit 100º today.")).to include("100°")
    end
  end
end
