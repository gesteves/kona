module Admin
  # Connects a Threads account with the OAuth2 authorization code flow.
  #
  # There is no form here, and Mastodon has one: the Meta dashboard gives the app credentials
  # through the environment, thus the owner names nothing and the Connect button of the card starts
  # the round trip. In that it is the same as Whoop.
  #
  # ⚠️ The callback is an admin page, thus the owner session controls it, and the one-time state
  # value controls it a second time. Meta redirects the browser of the owner back to this host, and
  # that browser has the session.
  class ThreadsController < BaseController
    include OauthState

    # GET /connected-apps/threads/authorize
    def authorize
      url = Threads.new.authorization_url(issue_oauth_state(:threads), redirect_uri: threads_callback_url)

      if url.nil?
        redirect_to connected_apps_path, status: :see_other,
                    alert: t("admin.threads.flash.unconfigured")
      else
        redirect_to url, allow_other_host: true
      end
    end

    # GET /connected-apps/threads/callback
    def callback
      return connection_denied(t("admin.threads.flash.unauthorized", error: params[:error_description] || params[:error])) if params[:error].present?
      return connection_denied(t("admin.oauth.invalid_state")) unless valid_oauth_state?(:threads, params[:state])

      if params[:code].present? && Threads.new.connect!(params[:code], redirect_uri: threads_callback_url)
        consume_oauth_state(:threads)
        redirect_to connected_apps_path, notice: t("admin.threads.flash.connected")
      else
        connection_denied(t("admin.threads.flash.no_token"))
      end
    end

    # DELETE /connected-apps/threads
    def destroy
      Threads.new.disconnect!
      redirect_to connected_apps_path, status: :see_other, notice: t("admin.threads.flash.disconnected")
    end

    private

    # Sends the owner back to the Connected apps page with the cause. This controller has no page
    # of its own.
    # @param message [String]
    def connection_denied(message)
      redirect_to connected_apps_path, status: :see_other, alert: message
    end
  end
end
