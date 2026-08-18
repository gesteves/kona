# Presents one external integration for the Connected apps page.
#
# These integrations keep their credentials in Redis rather than a database, so "connected" is a
# live check made at render time, not a persisted flag — which is also why the two booleans are
# passed in rather than read here: the view stays free of service calls.
class ConnectedAppPresenter
  attr_reader :name, :description, :connect_path, :disconnect_path

  # @param name [String] Display name, e.g. "Whoop".
  # @param description [String] One line on what the integration does.
  # @param configured [Boolean] Whether its credentials are set in the environment.
  # @param connected [Boolean] Whether an account is currently attached.
  # @param connect_path [String] Where the "Connect" link points.
  # @param disconnect_path [String] Where the "Disconnect" button posts.
  def initialize(name:, description:, configured:, connected:, connect_path:, disconnect_path:)
    @name = name
    @description = description
    @configured = configured
    @connected = connected
    @connect_path = connect_path
    @disconnect_path = disconnect_path
  end

  # Unconfigured is distinct from disconnected on purpose: the first is a deployment problem
  # (missing env vars) and offers no action, the second is a one-click fix.
  # @return [Symbol] :unconfigured, :disconnected, or :connected.
  def state
    return :unconfigured unless @configured

    @connected ? :connected : :disconnected
  end

  # @return [String] The badge label for the current state.
  def status_label
    { unconfigured: "Not configured", disconnected: "Not connected", connected: "Connected" }.fetch(state)
  end

  # @return [String] The Web Awesome badge variant for the current state.
  def status_variant
    { unconfigured: "neutral", disconnected: "warning", connected: "success" }.fetch(state)
  end

  # @return [Boolean] Whether to offer the connect action.
  def connectable?
    state == :disconnected
  end

  # @return [Boolean] Whether to offer the disconnect action.
  def disconnectable?
    state == :connected
  end
end
