module AdminHelper
  # The admin sidebar's items, in display order.
  #
  # Kept as data rather than hand-written markup so the `data-drawer="close"`, `aria-current`, and
  # icon handling in layouts/_admin_nav.html.erb is written once — this list is expected to grow.
  # `external: true` marks a destination outside the Rails admin UI, which opens in a new tab.
  # @return [Array<Hash>] Each with :label, :path, :icon (icon_svg's three arguments), and
  #   optionally :external.
  def admin_nav_items
    [
      { label: "Dashboard",          path: root_path,               icon: %w[classic light gauge] },
      { label: "Connected accounts", path: connected_accounts_path, icon: %w[classic light plug] },
      { label: "Sidekiq",            path: "/sidekiq",              icon: %w[classic light layer-group], external: true }
    ]
  end

  # Whether a nav item points at the page being rendered.
  #
  # ⚠️ Exact match, deliberately. A prefix match would light up "Dashboard" (now `/`) on every
  # page in the admin. External items never match — they render in their own tab.
  # @param path [String]
  # @return [Boolean]
  def admin_nav_current?(path)
    request.path == path
  end
end
