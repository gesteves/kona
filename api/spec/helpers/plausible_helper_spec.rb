require "rails_helper"

RSpec.describe PlausibleHelper do
  subject(:helper) do
    Class.new do
      include ActiveSupport::NumberHelper
      include PlausibleHelper
    end.new
  end

  it { expect(helper.pageviews_label(0)).to eq("Never viewed") }
  it { expect(helper.pageviews_label(1)).to eq("Viewed once") }
  it { expect(helper.pageviews_label(2)).to eq("Viewed twice") }
  it { expect(helper.pageviews_label(1234)).to eq("Viewed 1,234 times") }

  describe "#article_click_classes" do
    it "makes the name class and the section class" do
      expect(helper.article_click_classes("Trending Articles"))
        .to eq("plausible-event-name=Article+Click plausible-event-section=Trending+Articles")
    end

    # ⚠️ A space in a value must become a "+". Without that, "You May Also Like" is four class
    # names, and the script then reads a section of "You".
    it "makes one class name from a section with a space" do
      expect(helper.article_click_classes("You May Also Like"))
        .to eq("plausible-event-name=Article+Click plausible-event-section=You+May+Also+Like")
    end

    # ⚠️ The name class on its own sends an event with no section, and nothing shows that error.
    it "gives nil for a blank section" do
      expect(helper.article_click_classes(nil)).to be_nil
      expect(helper.article_click_classes("")).to be_nil
    end
  end
end
