require "rails_helper"

# The Plausible goal for a click on a card is one custom event, and the two apps render the class
# names that send it: the build renders each card of the page, and this app renders the card of the
# trending widget, into the same page. The name of the event is in a constant in each app, thus a
# difference makes the trending section stop converting, and nothing gives that message. The api
# cannot read the file of web at run time — the Docker image holds `api/` only — thus this spec
# reads it, in the way that the srcsets contract does.
RSpec.describe "web ↔ api article-click contract" do
  web_path = Rails.root.join("../web/lib/helpers/site_helpers.rb")

  it "gives the event the same name in the two apps" do
    web_name = File.read(web_path)[/ARTICLE_CLICK_EVENT\s*=\s*"([^"]+)"/, 1]

    expect(web_name).to be_present,
      "web/lib/helpers/site_helpers.rb has no ARTICLE_CLICK_EVENT constant."
    expect(PlausibleHelper::ARTICLE_CLICK_EVENT).to eq(web_name),
      "The api sends #{PlausibleHelper::ARTICLE_CLICK_EVENT.inspect} and web sends " \
      "#{web_name.inspect}. One goal in the Plausible dashboard matches one name only."
  end

  # ⚠️ The tracking script parses the class name with /plausible-event-(.+)(=|--)(.+)/, and it
  # changes each "+" into a space. Thus a section name with a space, an "=", or a "--" gives an
  # event with the wrong section, or no event.
  it "makes a class name that the tracking script can parse" do
    helper = Class.new { include PlausibleHelper }.new

    expect(helper.article_click_classes("Trending Articles"))
      .to eq("plausible-event-name=Article+Click plausible-event-section=Trending+Articles")
  end
end
