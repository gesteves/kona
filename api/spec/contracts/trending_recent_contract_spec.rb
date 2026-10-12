require "rails_helper"

# The home page lists the newest Articles as "Recent Articles", directly above the trending widget,
# and the widget leaves out that same number of Articles. The build renders the first list and this
# app renders the second one, thus a difference repeats an article on the home page or hides one
# from both lists. This spec reads the web file, in the way that the srcsets contract does.
RSpec.describe "web ↔ api recent-articles contract" do
  web_path = Rails.root.join("../web/lib/helpers/article_helpers.rb")

  it "leaves out of the trending list the same number of Articles that the home page lists" do
    web_count = File.read(web_path)[/def recent_articles\(count: (\d+)/, 1]

    expect(web_count).to be_present,
      "web/lib/helpers/article_helpers.rb has no `def recent_articles(count: N` line."
    expect(TrendingArticles::RECENT_EXCLUDED).to eq(Integer(web_count)),
      "TrendingArticles::RECENT_EXCLUDED is #{TrendingArticles::RECENT_EXCLUDED}, and the home " \
      "page lists #{web_count} recent articles."
  end
end
