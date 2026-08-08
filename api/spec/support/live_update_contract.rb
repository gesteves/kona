# The web↔api markup contract (root CLAUDE.md). Every /widgets/* fragment replaces a placeholder
# element in the static site, so its outermost element must carry the live-update wiring itself —
# otherwise it stops refreshing after the first swap.
#
# ⚠️ The placeholder flag is the dangerous half. It means "I am an empty skeleton", and the web
# controller reads it to decide whether a failed fetch should remove the element. On a rendered
# fragment it would turn a transient network blip into deleted content, so no api response may
# ever carry it. Nothing else in either app enforces this.
RSpec.shared_examples "a live-update fragment" do |path|
  it "carries the live-update wiring so it keeps refreshing after the first swap" do
    get path, headers: auth_headers

    expect(response.body).to include('data-controller="live-update"')
    expect(response.body).to include(%(data-live-update-url-value="#{path}"))
    expect(response.body).to include('data-action="visibilitychange@document->live-update#handleVisibilityChange"')
  end

  it "is not marked as a placeholder" do
    get path, headers: auth_headers

    expect(response.body).not_to include("data-live-update-placeholder-value")
  end

  # The placeholder carries aria-busy="true" while its skeleton is on screen. A fragment is the
  # finished content, so carrying it over would leave the region announced as perpetually loading.
  it "is not marked as busy" do
    get path, headers: auth_headers

    expect(response.body).not_to include("aria-busy")
  end
end
