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
  end
end
