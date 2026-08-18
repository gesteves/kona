# Presents one external integration for the Connected apps page.
#
# These integrations keep their credentials in Redis rather than a database, so "connected" is a
# live check made at render time, not a persisted flag — which is also why the state is passed in
# rather than read here: the view stays free of service calls.
class ConnectedAppPresenter
  attr_reader :name, :description, :connect_path, :disconnect_path, :error

  # @param name [String] Display name, e.g. "Whoop".
  # @param description [String] One line on what the integration does.
  # @param configured [Boolean] Whether its credentials are set in the environment.
  # @param connected [Boolean] Whether an account is currently attached.
  # @param connect_path [String] Where the "Connect" link points.
  # @param disconnect_path [String] Where the "Disconnect" button posts.
  # @param error [String, nil] Why an attached account no longer works, e.g. credentials the
  #   service has since rejected. nil when it's healthy.
  def initialize(name:, description:, configured:, connected:, connect_path:, disconnect_path:, error: nil)
    @name = name
    @description = description
    @configured = configured
    @connected = connected
    @connect_path = connect_path
    @disconnect_path = disconnect_path
    @error = error
  end

  # Unconfigured is distinct from disconnected on purpose: the first is a deployment problem
  # (missing env vars) and offers no action, the second is a one-click fix. :error is the third
  # distinction — credentials are attached but the service has rejected them, which is
  # indistinguishable from :connected in Redis and would otherwise show as healthy forever.
  # @return [Symbol] :unconfigured, :disconnected, :connected, or :error.
  def state
    return :unconfigured unless @configured
    return :disconnected unless @connected

    @error.present? ? :error : :connected
  end

  # @return [String] The badge label for the current state.
  def status_label
    {
      unconfigured: "Not configured", disconnected: "Not connected",
      connected: "Connected", error: "Needs attention"
    }.fetch(state)
  end

  # @return [String] The Web Awesome badge variant for the current state.
  def status_variant
    {
      unconfigured: "neutral", disconnected: "warning",
      connected: "success", error: "danger"
    }.fetch(state)
  end

  # @return [Boolean] Whether the credentials are missing outright, leaving nothing to act on.
  def unconfigured?
    state == :unconfigured
  end

  # An errored app offers connect as well — re-authorizing *is* the fix, and requiring a
  # disconnect first would throw away the only thing distinguishing it from a fresh setup.
  # @return [Boolean] Whether to offer the connect action.
  def connectable?
    state == :disconnected || state == :error
  end

  # @return [Boolean] Whether to offer the disconnect action.
  def disconnectable?
    state == :connected || state == :error
  end

  # @return [String] The label for the connect action.
  def connect_label
    state == :error ? "Reconnect" : "Connect"
  end
end
