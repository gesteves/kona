# The markup contract between web and api (refer to the root CLAUDE.md). Each /widgets/* fragment
# replaces a placeholder element in the static site, thus its outermost element must have the
# live-update attributes. Without them it gets no new content after the first swap.
#
# ⚠️ The placeholder flag is the dangerous half. It means "I am an empty skeleton", and the web
# controller reads it to decide if a failed fetch must remove the element. On a rendered fragment,
# it would make a short network problem into a loss of content. Thus no api response can have it.
# Nothing else in either app enforces this rule.
RSpec.shared_examples "a live-update fragment" do |path|
  it "carries the live-update wiring so it keeps refreshing after the first swap" do
    get path, headers: auth_headers

    expect(response.body).to include('data-controller="live-update"')
    expect(response.body).to include(%(data-live-update-url-value="#{path}"))
    expect(response.body).to include('data-action="visibilitychange@document->live-update#handleVisibilityChange"')
  end

  # A hidden hint, an icon, or a title goes into a link through a helper, and a SafeBuffer escapes
  # a plain string that a caller adds to it. The page then shows the markup as text.
  it "renders no escaped markup" do
    get path, headers: auth_headers

    expect(response.body).not_to match(/&lt;(span|svg|i|a)\b/)
  end

  it "is not marked as a placeholder" do
    get path, headers: auth_headers

    expect(response.body).not_to include("data-live-update-placeholder-value")
  end

  # The placeholder has aria-busy="true" while its skeleton is on the screen. A fragment is the
  # complete content, thus that attribute on a fragment would make a screen reader say that the area
  # loads for all time.
  it "is not marked as busy" do
    get path, headers: auth_headers

    expect(response.body).not_to include("aria-busy")
  end

  # ⚠️ The CSP belongs to the OwnerFacing pages and must stay there. A fragment is not a document:
  # the code puts it into a document that the web app already controls, and the edge cache would
  # hold this header with the body. A global default policy is what would break this rule.
  it "carries no Content-Security-Policy" do
    get path, headers: auth_headers

    expect(response.headers["Content-Security-Policy"]).to be_nil
    expect(response.headers["Content-Security-Policy-Report-Only"]).to be_nil
  end
end
