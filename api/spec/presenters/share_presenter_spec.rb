require "rails_helper"

RSpec.describe SharePresenter do
  def network(key: "bluesky", name: "Bluesky", account: "@me.bsky.social", connected: true)
    described_class::Network.new(key: key, name: name, account: account, connected: connected)
  end

  subject(:presenter) { described_class.new(networks: [ network ]) }

  describe "a network row" do
    it "names the account when one is connected" do
      expect(network.account_line).to eq("Posts as @me.bsky.social.")
    end

    it "says only Connected when the service gives no name" do
      expect(network(account: nil).account_line).to eq("Connected.")
    end

    it "answers connected?" do
      expect(network(connected: false)).not_to be_connected
    end
  end

  describe "the draft" do
    # ⚠️ A failed submit renders the page again, thus the owner must not lose what they wrote.
    it "puts each submitted value back" do
      presenter = described_class.new(networks: [ network ], body: "Hi", article_url: "https://x.test/",
                                      selected: [ "bluesky" ], scheduled: true, date: "2026-09-01",
                                      time: "09:00")

      expect(presenter.body).to eq("Hi")
      expect(presenter.article_url).to eq("https://x.test/")
      expect(presenter).to be_scheduled
      expect(presenter.date).to eq("2026-09-01")
      expect(presenter.time).to eq("09:00")
      expect(presenter.selected?("bluesky")).to be(true)
      expect(presenter.selected?("mastodon")).to be(false)
    end

    it "is blank on a first load" do
      expect(presenter.body).to eq("")
      expect(presenter.article_url).to eq("")
      expect(presenter).not_to be_scheduled
    end
  end

  describe "the limits" do
    # 300 is the Bluesky limit, which is the shortest of the three, and one body goes to all of
    # them. ⚠️ The view writes both numbers into the markup, and share_controller.js reads them
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
end
