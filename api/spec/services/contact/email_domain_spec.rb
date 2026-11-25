require "rails_helper"

RSpec.describe EmailDomain do
  let(:dns) { instance_double(Resolv::DNS, :timeouts= => nil) }

  before { allow(Resolv::DNS).to receive(:open).and_yield(dns) }

  def mx(exchange)
    Resolv::DNS::Resource::IN::MX.new(10, Resolv::DNS::Name.create(exchange))
  end

  describe ".accepts_mail?" do
    it "is true for a domain with an MX record, and asks for the absolute name" do
      allow(dns).to receive(:getresources).and_return([ mx("mx.example.com.") ])

      expect(described_class.accepts_mail?("jane@Example.com")).to be(true)
      # ⚠️ The flag goes into the default configuration. A Hash with the flag alone has no nameserver.
      expect(Resolv::DNS).to have_received(:open)
        .with(Resolv::DNS::Config.default_config_hash.merge(raise_timeout_errors: true))
      expect(dns).to have_received(:timeouts=).with(described_class::TIMEOUT_SECONDS)
      expect(dns).to have_received(:getresources)
        .with(Resolv::DNS::Name.create("example.com."), Resolv::DNS::Resource::IN::MX)
    end

    # Resolv gives an empty list for an NXDOMAIN and for an answer with no MX.
    it "is false for a domain with no MX record" do
      allow(dns).to receive(:getresources).and_return([])

      expect(described_class.accepts_mail?("someone@gmail.con")).to be(false)
    end

    it "is false for a null MX (RFC 7505)" do
      allow(dns).to receive(:getresources).and_return([ mx(".") ])

      expect(described_class.accepts_mail?("jane@example.com")).to be(false)
    end

    it "raises LookupError when the lookup times out" do
      allow(dns).to receive(:getresources).and_raise(Resolv::ResolvError, "DNS resolv timeout: example.com.")

      expect { described_class.accepts_mail?("jane@example.com") }.to raise_error(EmailDomain::LookupError)
    end
  end
end
