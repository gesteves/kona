# Presents one external integration for the Connected apps page.
#
# Each integration holds its credentials in Redis, thus "connected" is a live check and not a
# stored flag. The caller gives the state, thus the view makes no service call.
class ConnectedAppPresenter
  attr_reader :name, :description, :connect_path, :disconnect_path, :error

  # @param connected [Boolean] True if an account is connected now.
  # @param error [String, nil] The cause of a failure of a connected account, for example
  #   credentials that the service refuses. It is nil when the account works.
  def initialize(name:, description:, connected:, connect_path:, disconnect_path:, error: nil)
    @name = name
    @description = description
    @connected = connected
    @connect_path = connect_path
    @disconnect_path = disconnect_path
    @error = error
  end

  # The DOM id of the Disconnect confirmation dialog of this card.
  #
  # ⚠️ It comes from the path, and not from the name: a DOM id must never come from a translated
  # word.
  def disconnect_dialog_id
    "disconnect-#{disconnect_path.to_s.parameterize}"
  end

  # ⚠️ :error is the state that Redis cannot show: the credentials are there but the service
  # refuses them. Without it the page would show the integration as good for all time.
  #
  # There is no :unconfigured state, on purpose. `Admin::ConnectedAppsController` leaves the card of
  # an integration with no configuration off the page.
  # @return [Symbol] :disconnected, :connected, or :error.
  def state
    return :disconnected unless @connected

    @error.present? ? :error : :connected
  end

  # ⚠️ This class has no view context, thus it calls `I18n.t` and not the bare `t`.
  def status_label
    I18n.t("admin.connected_apps.status.#{state}")
  end

  # @return [String] The Web Awesome badge variant for the current state.
  def status_variant
    { disconnected: "warning", connected: "success", error: "danger" }.fetch(state)
  end

  # An app in the error state also offers connect. A new authorization *is* the correction, and a
  # disconnect first would remove the one thing that makes it different from a new setup.
  def connectable?
    state == :disconnected || state == :error
  end

  def disconnectable?
    state == :connected || state == :error
  end

  def connect_label
    I18n.t("admin.connected_apps.connect.#{state == :error ? "again" : "new"}")
  end
end
