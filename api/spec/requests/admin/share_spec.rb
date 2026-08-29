require "rails_helper"

RSpec.describe "Admin share", type: :request do
  let(:owner_email) { "owner@example.com" }

  let(:published) do
    DeepOstruct.wrap(
      title: "Ironman Canada", summary: "A long day in Penticton.", slug: "ironman-canada",
      draft: false, published_at: "2026-07-12T00:00:00Z", entry_type: "Article",
      path: "/2026/07/12/ironman-canada/", sys: { id: "entry-1" }
    )
  end

  let(:short) do
    DeepOstruct.wrap(
      title: "A short note", summary: "Small.", slug: "a-short-note",
      draft: false, published_at: "2026-08-01T00:00:00Z", entry_type: "Short",
      path: "/2026/08/01/a-short-note/", sys: { id: "entry-2" }
    )
  end

  let(:draft) do
    DeepOstruct.wrap(
      title: "Not ready yet", summary: "Hidden.", slug: "not-ready-yet",
      draft: true, published_at: "2026-08-20T00:00:00Z", entry_type: "Article",
      path: nil, sys: { id: "entry-3" }
    )
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("OWNER_EMAIL").and_return(owner_email)
    allow(ENV).to receive(:[]).with("SITE_URL").and_return("https://example.test")
    allow_any_instance_of(FontAwesome).to receive(:svg).and_return('<svg class="stub-icon"></svg>')
    allow_any_instance_of(Articles).to receive(:list).and_return([ published, short, draft ])

    # The credentials of each network live in Redis. Each example says which ones are connected.
    $redis.del(BlueskyCredentials::REDIS_KEY, MastodonCredentials::REDIS_KEY, ThreadsCredentials::REDIS_KEY)
    connect(bluesky: true, mastodon: false, threads: false)
  end

  after { $redis.del(BlueskyCredentials::REDIS_KEY, MastodonCredentials::REDIS_KEY, ThreadsCredentials::REDIS_KEY) }

  def connect(bluesky:, mastodon:, threads:)
    allow_any_instance_of(StandardSite).to receive(:connected?).and_return(bluesky)
    allow_any_instance_of(StandardSite).to receive(:handle).and_return(bluesky ? "me.bsky.social" : nil)
    allow_any_instance_of(Mastodon).to receive(:connected?).and_return(mastodon)
    allow_any_instance_of(Mastodon).to receive(:handle).and_return(mastodon ? "@me@instance.test" : nil)
    allow_any_instance_of(Threads).to receive(:connected?).and_return(threads)
    allow_any_instance_of(Threads).to receive(:username).and_return(threads ? "me" : nil)
  end

  describe "GET /share" do
    it "needs the owner session" do
      get "/share"

      expect(response).to redirect_to("/signin")
    end

    context "when one account is connected" do
      before { sign_in_as(email: owner_email) }

      it "renders the composer and does not cache it" do
        get "/share"

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("<wa-combobox")
        expect(response.body).to include("<wa-textarea")
        expect(response.headers["Cache-Control"]).to include("no-store")
      end

      # A Short is a published entry, thus the owner can share one. ⚠️ This is why the presenter
      # does not reuse ArticleRanking#candidates, which removes each Short.
      it "offers each published entry, and a Short with them" do
        get "/share"

        expect(response.body).to include("https://example.test/2026/07/12/ironman-canada/")
        expect(response.body).to include("https://example.test/2026/08/01/a-short-note/")
      end

      it "leaves a draft out of the picker" do
        get "/share"

        expect(response.body).not_to include("Not ready yet")
      end

      it "writes the character limit into the markup for the controller to read" do
        get "/share"

        expect(response.body).to include(%(data-share-limit-value="#{SharePresenter::BODY_LIMIT}"))
        expect(response.body).to include(%(data-share-warn-at-value="#{SharePresenter::WARN_AT}"))
      end

      # The server renders the first count, thus the line has its height before the JavaScript
      # runs and the page does not move.
      it "renders the first count line" do
        get "/share"

        expect(response.body).to include("0 / #{SharePresenter::BODY_LIMIT}")
      end

      it "names the account of a connected network and disables one that is not connected" do
        get "/share"

        expect(response.body).to include("Posts as @me.bsky.social.")
        expect(response.body).to include('<wa-checkbox name="networks[]" value="mastodon" disabled>')
        expect(response.body).to include("Not connected.")
      end

      # ⚠️ The house rule: every submit is a <wa-button> in a form_with, and never a native button.
      it "renders no native button" do
        get "/share"

        expect(response.body).not_to include("<button")
      end

      it "puts the item in the nav" do
        get "/share"

        expect(response.body).to include("Share a post")
      end
    end

    # ⚠️ The page is a draft screen, thus it renders with no account at all. Each row is then
    # disabled, and the owner can still look at the page and change it.
    context "when no account is connected" do
      before do
        connect(bluesky: false, mastodon: false, threads: false)
        sign_in_as(email: owner_email)
      end

      it "still renders the composer" do
        get "/share"

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("<wa-combobox")
      end

      it "disables each of the three rows" do
        get "/share"

        %w[bluesky mastodon threads].each do |key|
          expect(response.body).to include(%(<wa-checkbox name="networks[]" value="#{key}" disabled>))
        end
      end

      it "keeps the item in the nav" do
        get "/connected-apps"

        expect(response.body).to include("Share a post")
      end
    end
  end
end
