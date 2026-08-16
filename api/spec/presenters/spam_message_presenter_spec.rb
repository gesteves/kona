require "rails_helper"

RSpec.describe SpamMessagePresenter do
  subject(:presenter) { described_class.new(payload: payload, not_spam_path: "/contact/abc/not-spam", delete_path: "/contact/abc") }

  let(:payload) do
    {
      "id" => "abc",
      "name" => "Ivan",
      "email" => "ivan@example.com",
      "message" => "cheap pills",
      "context" => { "ip" => "203.0.113.7", "user_agent" => "Mozilla/5.0", "city" => "Boise", "region" => "Idaho", "country" => "US" },
      "received_at" => "2026-08-01T12:00:00Z"
    }
  end

  it "exposes the message fields" do
    expect(presenter).to have_attributes(
      id: "abc", name: "Ivan", email: "ivan@example.com", message: "cheap pills",
      received_at: "2026-08-01T12:00:00Z",
      not_spam_path: "/contact/abc/not-spam", delete_path: "/contact/abc"
    )
  end

  it "joins the forwarded geo fields the way the email does" do
    expect(presenter.location).to eq("Boise, Idaho, US")
  end

  it "omits blanks from the location" do
    payload["context"] = { "country" => "US" }
    expect(presenter.location).to eq("US")
  end

  it "has no location when the proxy forwarded none" do
    payload["context"] = { "ip" => "203.0.113.7" }
    expect(presenter.location).to be_nil
  end

  it "exposes the forwarded IP and user agent" do
    expect(presenter.ip).to eq("203.0.113.7")
    expect(presenter.user_agent).to eq("Mozilla/5.0")
  end

  it "reports nil for an IP and user agent the proxy didn't forward" do
    payload["context"] = {}

    expect(presenter.ip).to be_nil
    expect(presenter.user_agent).to be_nil
  end

  it "tolerates a missing context entirely" do
    payload["context"] = nil
    expect(presenter.location).to be_nil
    expect(presenter.ip).to be_nil
  end

  describe "the preview" do
    it "leaves a short message whole and needs no disclosure" do
      expect(presenter).not_to be_truncated
      expect(presenter.preview).to eq("cheap pills")
    end

    it "cuts a long message at a word boundary" do
      payload["message"] = "spam " * 200

      expect(presenter).to be_truncated
      expect(presenter.preview.length).to be <= described_class::PREVIEW_LIMIT
      expect(presenter.preview).to end_with("...")
      expect(presenter.message.length).to eq(1000)
    end
  end

  it "namespaces the confirmation dialog by message id" do
    expect(presenter.dialog_id).to eq("spam-delete-abc")
  end
end
