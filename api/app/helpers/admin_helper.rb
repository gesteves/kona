module AdminHelper
  # The admin sidebar's items, in display order.
  #
  # Kept as data rather than hand-written markup so the `data-drawer="close"`, `aria-current`, and
  # icon handling in layouts/_admin_nav.html.erb is written once — this list is expected to grow.
  # `external: true` marks a destination outside the Rails admin UI, which opens in a new tab.
  #
  # @param quarantine_count [Integer] Messages waiting in the spam quarantine. Passed in rather
  #   than read from an ivar, so this stays a pure function of its arguments like every other
  #   helper here.
  # @return [Array<Hash>] Each with :label, :path, :icon (icon_svg's three arguments), and
  #   optionally :badge and :external.
  def admin_nav_items(quarantine_count: 0)
    [
      { label: "Home",               path: root_path,               icon: %w[classic light house] },
      { label: "Location",           path: location_path,           icon: %w[classic light location-dot] },
      { label: "Contact",            path: contact_path,            icon: %w[classic light envelope],
        badge: quarantine_count.to_i.positive? ? quarantine_count.to_i : nil },
      { label: "Maps",               path: maps_path,               icon: %w[classic light map] },
      { label: "Connected accounts", path: connected_accounts_path, icon: %w[classic light plug] },
      { label: "Sidekiq",            path: "/sidekiq",              icon: %w[classic light layer-group], external: true }
    ]
  end

  # Whether a nav item points at the page being rendered.
  #
  # ⚠️ Exact match, deliberately. A prefix match would light up "Home" (now `/`) on every
  # page in the admin. External items never match — they render in their own tab.
  # @param path [String]
  # @return [Boolean]
  def admin_nav_current?(path)
    request.path == path
  end
end
