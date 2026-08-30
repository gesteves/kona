require "securerandom"

module Admin
  # Connects a Mastodon account with the OAuth2 authorization code flow.
  #
  # Whoop is different: its client comes from a dashboard and from env vars, thus its flow starts
  # at /whoop/auth with no form. Here the owner must name an instance first, because the app
  # registers itself on that instance. Thus all four actions are here and not on
  # ConnectedAppsController.
  #
  # ⚠️ The callback is an admin page, thus the owner session controls it, and the one-time state
  # value controls it a second time. The Whoop callback cannot do that: Whoop redirects to a
  # public host. Mastodon redirects the browser of the owner back to this host, and that browser
  # has the session.
  class MastodonController < BaseController
    STATE_CACHE_KEY = "mastodon:oauth:state".freeze

    # GET /connected-apps/mastodon
    def show
      credentials = MastodonCredentials.fetch
      @instance = credentials.instance
      @handle = credentials.handle
    end

    # POST /connected-apps/mastodon
    #
    # It registers the app on the instance, then sends the owner there to authorize it.
    def create
      @instance = Mastodon.normalize_instance(params[:instance])

      if @instance.blank?
        @instance = params[:instance]
        return connection_failed(t("admin.mastodon.flash.not_an_instance"))
      end

      unless Mastodon.new.register!(instance: @instance, redirect_uri: mastodon_callback_url)
        return connection_failed(t("admin.mastodon.flash.refused", instance: @instance))
      end

      # A new instance of the service, because the registration above is what stored the client
      # that this URL needs.
      redirect_to Mastodon.new.authorization_url(issue_state), allow_other_host: true
    end

    # GET /connected-apps/mastodon/callback
    def callback
      return connection_denied(t("admin.mastodon.flash.unauthorized", error: params[:error])) if params[:error].present?
      return connection_denied(t("admin.oauth.invalid_state")) unless valid_state?(params[:state])

      $redis.del(STATE_CACHE_KEY)

      if params[:code].present? && Mastodon.new.connect!(params[:code])
        redirect_to connected_apps_path, notice: t("admin.mastodon.flash.connected")
      else
        connection_denied(t("admin.mastodon.flash.no_token"))
      end
    end

    # DELETE /connected-apps/mastodon
    def destroy
      Mastodon.new.disconnect!
      redirect_to connected_apps_path, status: :see_other, notice: t("admin.mastodon.flash.disconnected")
    end

    private

    # Renders the form again with the cause. The owner keeps what they typed.
    # @param message [String]
    def connection_failed(message)
      flash.now[:alert] = message
      render :show, status: :unprocessable_content
    end

    # Sends the owner back to the form with the cause. The callback has no form of its own.
    # @param message [String]
    def connection_denied(message)
      redirect_to mastodon_connection_path, status: :see_other, alert: message
    end

    # @return [String] A one-time value for the round trip.
    def issue_state
      state = SecureRandom.hex(16)
      $redis.setex(STATE_CACHE_KEY, 10.minutes, state)
      state
    end

    # @param state [String, nil] The value that came back from the instance.
    # @return [Boolean]
    def valid_state?(state)
      expected = $redis.get(STATE_CACHE_KEY)
      state.present? && expected.present? && ActiveSupport::SecurityUtils.secure_compare(state, expected)
    end
  end
end
