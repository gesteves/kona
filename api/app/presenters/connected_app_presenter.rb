# Presents one external integration for the Connected apps page.
#
# Each of these integrations holds its credentials in Redis, and not in a database. Thus
# "connected" is a live check at render time, and not a stored flag. That is also why the caller
# gives the state and this class does not read it: the view then makes no service call.
class ConnectedAppPresenter
  attr_reader :name, :description, :connect_path, :disconnect_path, :error

  # @param name [String] The name on the screen, for example "Whoop".
  # @param description [String] One line that says what the integration does.
  # @param connected [Boolean] True if an account is connected now.
  # @param connect_path [String] The path of the "Connect" link.
  # @param disconnect_path [String] The path that the "Disconnect" button posts to.
  # @param error [String, nil] The cause of a failure of a connected account, for example
  #   credentials that the service now refuses. It is nil when the account works.
  def initialize(name:, description:, connected:, connect_path:, disconnect_path:, error: nil)
    @name = name
    @description = description
    @connected = connected
    @connect_path = connect_path
    @disconnect_path = disconnect_path
    @error = error
  end

  # ⚠️ :error is the state that Redis cannot show: the credentials are there but the service
  # refuses them. Without it the page would show the integration as good for all time.
  #
  # There is no :unconfigured state, on purpose. An integration whose configuration is absent
  # cannot operate, thus `Admin::ConnectedAppsController` leaves its card off the page and does not
  # render one with no action.
  # @return [Symbol] :disconnected, :connected, or :error.
  def state
    return :disconnected unless @connected

    @error.present? ? :error : :connected
  end

  # ⚠️ This class has no view context, thus it calls `I18n.t` and not the bare `t`.
  # @return [String] The label of the badge for the current state.
  def status_label
    I18n.t("admin.connected_apps.status.#{state}")
  end

  # @return [String] The Web Awesome badge variant for the current state.
  def status_variant
    { disconnected: "warning", connected: "success", error: "danger" }.fetch(state)
  end

  # An app in the error state also offers connect. A new authorization *is* the correction, and a
  # disconnect first would remove the one thing that makes it different from a new setup.
  # @return [Boolean] True to offer the connect action.
  def connectable?
    state == :disconnected || state == :error
  end

  # @return [Boolean] True to offer the disconnect action.
  def disconnectable?
    state == :connected || state == :error
  end

  # @return [String] The label of the connect action.
  def connect_label
    I18n.t("admin.connected_apps.connect.#{state == :error ? "again" : "new"}")
  end
end
