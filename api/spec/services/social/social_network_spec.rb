require "rails_helper"

RSpec.describe SocialNetwork do
  it "lists the three networks in the order of the page" do
    expect(described_class.keys).to eq(%w[bluesky mastodon threads])
    expect(described_class.all.map(&:job)).to eq([ BlueskyPostJob, MastodonPostJob, ThreadsPostJob ])
  end

  it "takes each limit from the class of its network" do
    expect(described_class.all.map(&:length_limit)).to eq([ 300, 500, 500 ])
    expect(described_class.all.map(&:photo_limit)).to eq([ 10, 4, 20 ])
    expect(described_class.all.map(&:alt_limit)).to eq([ 2000, 1500, 1000 ])
  end

  it "knows what each network does with a link, a Markdown link, and a topic" do
    expect(described_class.all.map(&:link)).to eq(%i[card text attachment])
    expect(described_class.all.select(&:markdown?).map(&:key)).to eq(%w[bluesky])
    expect(described_class.all.select(&:topic?).map(&:key)).to eq(%w[threads])
  end

  it "pins the most photos to Bluesky and the alt limit to the smallest of the three networks" do
    expect(described_class::MAX_PHOTOS).to eq(Bluesky::MAX_IMAGES)
    expect(described_class::ALT_LIMIT).to eq(Threads::MAX_ALT_TEXT_CHARACTERS)
  end

  it "names a network from the locale file" do
    expect(described_class.fetch("mastodon").name).to eq(I18n.t("admin.networks.mastodon"))
  end

  it "gives nil, or raises, for a key that is not a network" do
    expect(described_class.find("myspace")).to be_nil
    expect { described_class.fetch("myspace") }.to raise_error(KeyError)
  end
end
