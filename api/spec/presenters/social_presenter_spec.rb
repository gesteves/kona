require "rails_helper"

RSpec.describe SocialPresenter do
  def network(key: "bluesky", name: "Bluesky", account: "@me.bsky.social", connected: true)
    described_class::Network.new(key: key, name: name, account: account, connected: connected)
  end

  subject(:presenter) { described_class.new(networks: [ network ]) }

  describe "a network row" do
    it "names the account when one is connected" do
      expect(network.account_line).to eq(I18n.t("admin.social.account.named", account: "@me.bsky.social"))
    end

    it "says only Connected when the service gives no name" do
      expect(network(account: nil).account_line).to eq(I18n.t("admin.social.account.unnamed"))
    end

    it "answers connected?" do
      expect(network(connected: false)).not_to be_connected
    end
  end

  describe "the draft" do
    # ⚠️ A failed submit renders the page again, thus the owner must not lose what they wrote.
    it "puts each submitted post back, in order" do
      presenter = described_class.new(
        networks: [ network ],
        posts: [ { text: "One", link: "https://x.test/" }, { text: "Two", link: "" } ],
        selected: [ "bluesky" ], scheduled: true, date: "2026-09-01", time: "09:00"
      )

      expect(presenter.posts.map(&:text)).to eq(%w[One Two])
      expect(presenter.posts.map(&:link)).to eq([ "https://x.test/", "" ])
      expect(presenter).to be_scheduled
      expect(presenter.date).to eq("2026-09-01")
      expect(presenter.time).to eq("09:00")
      expect(presenter.selected?("bluesky")).to be(true)
      expect(presenter.selected?("mastodon")).to be(false)
    end

    # ⚠️ There is always at least one post, thus the view renders one empty block.
    it "gives one empty post on a first load" do
      presenter = described_class.new(networks: [ network ])

      expect(presenter.posts.length).to eq(1)
      expect(presenter.posts.first.text).to eq("")
      expect(presenter.posts.first.link).to eq("")
      expect(presenter).not_to be_scheduled
    end

    it "knows a thread from one post" do
      one = described_class.new(networks: [ network ], posts: [ { text: "One" } ])
      many = described_class.new(networks: [ network ], posts: [ { text: "One" }, { text: "Two" } ])

      expect(one).not_to be_thread
      expect(many).to be_thread
    end
  end

  describe "the limits" do
    # 300 is the Bluesky limit, which is the shortest of the three, and one body goes to all of
    # them. ⚠️ The view writes both numbers into the markup, and social_controller.js reads them
    # there.
    it "warns below the limit" do
      expect(described_class::WARN_AT).to be < described_class::BODY_LIMIT
      expect(described_class::BODY_LIMIT).to eq(300)
    end

    # ⚠️ There is no max_date, on purpose: a post can wait as long as the owner wants.
    it "offers today as the first day and no last day" do
      expect(presenter.min_date).to match(/\A\d{4}-\d{2}-\d{2}\z/)
      expect(presenter).not_to respond_to(:max_date)
    end
  end

  # ⚠️ A field for an account that cannot take a post is only noise. That is different from the
  # "Post to" list, which keeps a disabled row to say why a name is not available.
  describe "#mention_networks" do
    it "gives the connected networks only" do
      presenter = described_class.new(networks: [
        SocialPresenter::Network.new(key: "bluesky", name: "Bluesky", connected: true),
        SocialPresenter::Network.new(key: "mastodon", name: "Mastodon", connected: false)
      ])

      expect(presenter.mention_networks.map(&:key)).to eq([ "bluesky" ])
    end
  end
end
