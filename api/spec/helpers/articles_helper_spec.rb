require "rails_helper"

RSpec.describe ArticlesHelper do
  subject(:helper) do
    Class.new do
      include ActionView::Helpers::TagHelper
      include ArticlesHelper
    end.new
  end

  describe "#article_permalink_timestamp" do
    let(:article) { DeepOstruct.wrap(path: "/2024/01/01/hello/", published_at: "2024-01-01T10:00:00Z") }

    it "links to the article path and carries the publish-date target" do
      result = helper.article_permalink_timestamp(article)
      expect(result).to include('href="/2024/01/01/hello/"')
      expect(result).to include('data-publish-date-target="timestamp"')
    end

    it "renders the publication date as the (no-JS fallback) text" do
      expect(helper.article_permalink_timestamp(article)).to include("Monday, January 1, 2024")
    end

    it "wraps the anchor in a <time> carrying the machine-readable publish instant" do
      result = helper.article_permalink_timestamp(article)
      expect(result).to start_with('<time datetime="2024-01-01T10:00:00+00:00">')
      expect(result).to end_with("</time>")
    end

    # ⚠️ The page of the article renders this link too, and it points at that same page. Thus a
    # class attribute must be absent when the caller gives no class.
    it "writes no class attribute with no link_class" do
      expect(helper.article_permalink_timestamp(article)).not_to include("class=")
    end

    it "puts link_class on the anchor" do
      result = helper.article_permalink_timestamp(article, link_class: "tracking")
      expect(result).to include('class="tracking"')
    end
  end
end
