# The setup that each request spec of the admin UI needs: the address of the owner, and an icon
# that needs no Font Awesome request. It does not sign in: an example calls
# `sign_in_as(email: owner_email)` for that.
RSpec.shared_context "the admin UI" do
  let(:owner_email) { "owner@example.com" }

  before do
    stub_env("OWNER_EMAIL" => owner_email)
    allow_any_instance_of(FontAwesome).to receive(:svg).and_return('<svg class="stub-icon"></svg>')
  end
end
