require "rails_helper"

# The live-update controller of the site gets a fragment again only through the `data-action` of
# the element. The build writes that attribute on each placeholder and this app writes it on each
# fragment that replaces one. Thus a difference gives a widget that swaps in and then never gets new
# content, and nothing gives that message. This spec reads the web file, in the way that the srcsets
# contract does.
RSpec.describe "web ↔ api live-update attributes contract" do
  web_method = File.read(Rails.root.join("../web/lib/helpers/site_helpers.rb"))[/def live_update_attrs.*?^  end$/m].to_s

  let(:api_attrs) do
    Class.new do
      include LiveUpdateHelper

      def live_update_url = "/widgets/whoop"
    end.new.live_update_attrs
  end

  %w[data-controller data-action].each do |attribute|
    it "writes the same #{attribute} in the two apps" do
      web_value = web_method[/#{attribute}="([^"]+)"/, 1]

      expect(web_value).to be_present,
        "web/lib/helpers/site_helpers.rb has no #{attribute} in live_update_attrs."
      expect(api_attrs[/#{attribute}="([^"]+)"/, 1]).to eq(web_value)
    end
  end
end
