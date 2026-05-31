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
end
