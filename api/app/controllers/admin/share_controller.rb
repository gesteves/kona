module Admin
  # The Share composer: it picks a published entry, drafts one body for the three networks, and
  # selects which of them get it.
  #
  # ⚠️ Nothing here posts. The Share button is inert, and this controller has one read action.
  class ShareController < BaseController
    # GET /share
    #
    # ⚠️ The page renders with no account connected, and each row is then disabled. It is a draft
    # screen, thus it must be available to look at and to change before an account exists.
    def show
      @share = SharePresenter.new(
        articles: Articles.new.list,
        networks: social_networks,
        site_url: ENV["SITE_URL"].to_s
      )
    end

    private

    # The networks that this page can post to, in a stable order.
    #
    # ⚠️ Each answer comes from Redis, and no service makes an HTTP request.
    # `StandardSite#connected?` has that same rule, and its comment gives the reason: an upstream
    # failure must not go into the path of a page load.
    # @return [Array<SharePresenter::Network>]
    def social_networks
      bluesky = StandardSite.new
      mastodon = Mastodon.new
      threads = Threads.new

      [
        SharePresenter::Network.new(
          key: "bluesky", name: "Bluesky", connected: bluesky.connected?,
          account: ("@#{bluesky.handle}" if bluesky.handle.present?)
        ),
        SharePresenter::Network.new(
          key: "mastodon", name: "Mastodon", connected: mastodon.connected?,
          account: mastodon.handle
        ),
        SharePresenter::Network.new(
          key: "threads", name: "Threads", connected: threads.connected?,
          account: ("@#{threads.username}" if threads.username.present?)
        )
      ]
    end
  end
end
