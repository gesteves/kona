module AdminHelper
  # The admin sidebar's ungrouped items, in display order — the two that are used often enough to
  # want no click before reaching them. Everything else lives in a group; see #admin_nav_groups.
  #
  # Kept as data rather than hand-written markup so the `data-drawer="close"`, `aria-current`, and
  # icon handling in layouts/_admin_nav_item.html.erb is written once.
  # `external: true` marks a destination outside the Rails admin UI, which opens in a new tab.
  #
  # @param quarantine_count [Integer] Messages waiting in the spam quarantine. Passed in rather
  #   than read from an ivar, so this stays a pure function of its arguments like every other
  #   helper here.
  # @return [Array<Hash>] Each with :label, :path, and :icon (icon_svg's three arguments), plus
  #   optionally :badge and :external. Grouped items omit :icon; see #admin_nav_groups.
  def admin_nav_items(quarantine_count: 0)
    [
      { label: "Home", path: root_path, icon: %w[classic light house] },
      { label: "Spam", path: spam_path, icon: %w[classic light envelopes-bulk],
        badge: quarantine_count.to_i.positive? ? quarantine_count.to_i : nil }
    ]
  end

  # The sidebar's collapsible groups, in display order. Same item shape as #admin_nav_items.
  #
  # A group holding one item still earns its place: the split is by *what the page is for* —
  # something you make (Tools), something you configure (Settings), something you operate
  # (System) — so a new page has an obvious home rather than lengthening one flat list.
  #
  # ⚠️ Only the group carries an :icon; its items deliberately don't. One icon column per level
  # would read as two ragged columns, so a group's items are indented to sit under their group's
  # *label* instead — see `.admin-nav__groups` in _admin-nav.scss, which hardcodes that indent.
  # @return [Array<Hash>] Each with :label, :icon, and :items.
  def admin_nav_groups
    [
      { label: "Tools", icon: %w[classic light wrench], items: [
        { label: "Course maps", path: course_maps_path }
      ] },
      { label: "Settings", icon: %w[classic light gear], items: [
        { label: "Location",       path: location_path },
        { label: "Connected apps", path: connected_apps_path }
      ] },
      { label: "System", icon: %w[classic light server], items: [
        { label: "Sidekiq", path: "/sidekiq", external: true }
      ] }
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

  # Whether a group should render expanded.
  #
  # ⚠️ Server-rendered rather than remembered: every Turbo visit re-renders the sidebar, so the
  # expanded group is always the one holding the current page. A group whose only item is
  # external (System, today) therefore never opens on its own, since #admin_nav_current? can't
  # match a destination outside the admin.
  # @param group [Hash] One entry from #admin_nav_groups.
  # @return [Boolean]
  def admin_nav_group_expanded?(group)
    group[:items].any? { |item| admin_nav_current?(item[:path]) }
  end
end
