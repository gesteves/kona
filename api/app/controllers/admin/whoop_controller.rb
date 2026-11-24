module Admin
  # Connects a Whoop account with the OAuth2 authorization code flow. The app credentials come from
  # the environment, thus there is no form, as for Threads and Strava.
  #
  # ⚠️ The two paths are `/whoop/auth` and `/whoop/callback`, and not below `/connected-apps` as the
  # other apps are. `WHOOP_REDIRECT_URI` and the Whoop dashboard name the callback, thus a new path
  # needs a change there first.
  #
  # ⚠️ The callback is an admin page, thus the owner session controls it, and the one-time state
  # value controls it a second time. Whoop redirects the browser of the owner back to this host,
  # and that browser has the session.
  class WhoopController < BaseController
    include OauthState

    # GET /whoop/auth
    def authorize
      url = Whoop.new.authorization_url(issue_oauth_state(:whoop))

      if url.nil?
        redirect_to connected_apps_path, status: :see_other, alert: t("admin.whoop.flash.unconfigured")
      else
        redirect_to url, allow_other_host: true
      end
    end

    # GET /whoop/callback
    def callback
      return connection_denied(t("admin.whoop.flash.unauthorized", error: params[:error])) if params[:error].present?
      return connection_denied(t("admin.oauth.invalid_state")) unless valid_oauth_state?(:whoop, params[:state])

      if params[:code].present? && Whoop.new.connect!(params[:code])
        consume_oauth_state(:whoop)
        redirect_to connected_apps_path, notice: t("admin.whoop.flash.connected")
      else
        connection_denied(t("admin.whoop.flash.no_token"))
      end
    end

    # DELETE /connected-apps/whoop
    def destroy
      Whoop.new.disconnect!
      redirect_to connected_apps_path, status: :see_other, notice: t("admin.whoop.flash.disconnected")
    end

    private

    # Sends the owner back to the Connected apps page with the cause.
    def connection_denied(message)
      redirect_to connected_apps_path, status: :see_other, alert: message
    end
  end
end
