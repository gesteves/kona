require "rails_helper"

RSpec.describe ConnectedAppPresenter do
  subject(:app) { described_class.new(**attrs) }

  let(:attrs) do
    {
      name: "Whoop",
      description: "Syncs strain, sleep, and recovery.",
      configured: true,
      connected: true,
      connect_path: "/whoop/auth",
      disconnect_path: "/connected-apps/whoop"
    }
  end

  context "when the credentials aren't set" do
    let(:attrs) { super().merge(configured: false, connected: false) }

    it "offers no action — it's a deployment problem, not a one-click fix" do
      expect(app.state).to eq(:unconfigured)
      expect(app.status_label).to eq("Not configured")
      expect(app).to be_unconfigured
      expect(app).not_to be_connectable
      expect(app).not_to be_disconnectable
    end
  end

  context "when configured but nothing is attached" do
    let(:attrs) { super().merge(connected: false) }

    it "offers connect only" do
      expect(app.state).to eq(:disconnected)
      expect(app.status_label).to eq("Not connected")
      expect(app.connect_label).to eq("Connect")
      expect(app).to be_connectable
      expect(app).not_to be_disconnectable
    end
  end

  context "when attached and healthy" do
    it "offers disconnect only" do
      expect(app.state).to eq(:connected)
      expect(app.status_label).to eq("Connected")
      expect(app.status_variant).to eq("success")
      expect(app).not_to be_connectable
      expect(app).to be_disconnectable
    end
  end

  # This is the state that the error path exists for: the tokens are still in Redis, thus the code
  # cannot know it from :connected without the error value.
  context "when attached but the service has rejected the credentials" do
    let(:attrs) { super().merge(error: "Whoop rejected the last token refresh (HTTP 401).") }

    it "reports it as needing attention" do
      expect(app.state).to eq(:error)
      expect(app.status_label).to eq("Needs attention")
      expect(app.status_variant).to eq("danger")
    end

    it "offers reconnect as well as disconnect, since reconnecting is the fix" do
      expect(app).to be_connectable
      expect(app).to be_disconnectable
      expect(app.connect_label).to eq("Reconnect")
    end
  end

  # Bluesky uses this presenter and gives no error, thus a blank value must not become :error.
  it "ignores a blank error" do
    expect(described_class.new(**attrs.merge(error: "")).state).to eq(:connected)
  end
end
