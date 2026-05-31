# Shared behavior for the live-updating widget endpoints embedded in the static site:
# public HTTP caching headers, and an empty-body response the site's live-update Stimulus
# controller treats as a no-op (leaving the existing markup in place).
module LiveWidget
  extend ActiveSupport::Concern

  private

  # Sets public caching headers for an embedded widget fragment. Every widget uses the same
  # one-minute stale-while-revalidate window; only the fresh lifetime differs.
  # @param ttl [ActiveSupport::Duration] How long the fragment stays fresh.
  # @param stale_while_revalidate [ActiveSupport::Duration] The revalidation grace window.
  def cache_widget(ttl:, stale_while_revalidate: 1.minute)
    expires_in ttl, public: true, stale_while_revalidate: stale_while_revalidate
  end

  # Renders an empty body. The live-update controller no-ops on it, leaving the existing
  # markup in place rather than blanking the widget when data is unavailable.
  def render_empty
    render plain: ""
  end

  # Marks the response as uncacheable (Cache-Control: no-store), for endpoints that must
  # always serve a fresh value.
  def no_store!
    response.cache_control[:no_store] = true
  end
end
