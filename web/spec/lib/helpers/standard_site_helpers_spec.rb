require 'spec_helper'

RSpec.describe StandardSiteHelpers do
  describe "#document_rkey" do
    # The exact TID for the fixture sys.id is asserted here (and in api's matching spec)
    # so the two apps can never drift: the <link> AT URI must equal the published record.
    it "derives a valid 13-character TID from the Contentful sys.id" do
      rkey = document_rkey("6L1asJJq4umcGEvD0hfqxE")
      expect(rkey).to eq("3446ygrm3x4bk")
      expect(rkey).to match(/\A[234567abcdefghij][234567abcdefghijklmnopqrstuvwxyz]{12}\z/)
    end

    it "is stable for the same sys.id and distinct for different ones" do
      expect(document_rkey("6navMJAmcxXgFwFr0KxgOz")).to eq(document_rkey("6navMJAmcxXgFwFr0KxgOz"))
      expect(document_rkey("6navMJAmcxXgFwFr0KxgOz")).not_to eq(document_rkey("6L1asJJq4umcGEvD0hfqxE"))
    end
  end
end
