require "rails_helper"

RSpec.describe StandardSiteSyncJob do
  let(:service) { instance_double(StandardSite) }

  before { allow(StandardSite).to receive(:new).and_return(service) }

  it "dispatches sync_document with the entry id" do
    expect(service).to receive(:sync_document).with("entry123")
    described_class.new.perform("sync_document", "entry123")
  end

  it "dispatches delete_document with the entry id" do
    expect(service).to receive(:delete_document).with("entry123")
    described_class.new.perform("delete_document", "entry123")
  end

  it "dispatches sync_publication (ignoring any entry id)" do
    expect(service).to receive(:sync_publication).with(no_args)
    described_class.new.perform("sync_publication", "site1")
  end

  it "logs and ignores an unknown operation" do
    expect(service).not_to receive(:sync_document)
    expect(Rails.logger).to receive(:warn).with(/unknown operation/)
    described_class.new.perform("frobnicate", "entry123")
  end

  it "is configured to retry" do
    expect(described_class.get_sidekiq_options["retry"]).to eq(5)
  end
end
