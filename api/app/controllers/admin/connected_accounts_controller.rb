module Admin
  # Lists the external accounts this app holds credentials for, and lets the owner attach or
  # detach them. Whoop is the only one today; the page is a list so adding a second is a matter
  # of appending a presenter.
  class ConnectedAccountsController < BaseController
    # GET /admin/connected-accounts
    def show
      @accounts = [ whoop_account ]
    end

    # DELETE /admin/connected-accounts/whoop
    def whoop
      Whoop.new.disconnect!
      redirect_to connected_accounts_path, status: :see_other, notice: "Whoop disconnected."
    end

    private

    def whoop_account
      service = Whoop.new

      ConnectedAccountPresenter.new(
        name: "Whoop",
        description: "Syncs strain, sleep, and recovery to Intervals.icu, and powers the Whoop widget.",
        configured: service.valid_credentials?,
        connected: service.connected?,
        connect_path: "/whoop/auth",
        disconnect_path: whoop_connection_path
      )
    end
  end
end
