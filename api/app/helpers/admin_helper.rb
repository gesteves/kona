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
  #   optionally :badge and :external.
  def admin_nav_items(quarantine_count: 0)
    [
      { label: "Home", path: root_path, icon: %w[classic light house] },
      { label: "Spam", path: spam_path, icon: %w[classic light envelopes-bulk],
        badge: quarantine_count.to_i.positive? ? quarantine_count.to_i : nil }
    ]
  end

  # The sidebar's labelled groups, in display order. Same item shape as #admin_nav_items.
  #
  # A group holding one item still earns its place: the split is by *what the page is for* —
  # something you make (Tools), something you configure (Settings), something you operate
  # (More) — so a new page has an obvious home rather than lengthening one flat list.
  #
  # ⚠️ The group is a caption, not a link, so it carries no :icon of its own; its items each do,
  # in the same column as the ungrouped ones above.
  # @return [Array<Hash>] Each with :label and :items.
  def admin_nav_groups
    [
      { label: "Tools", items: [
        { label: "Course maps", path: course_maps_path, icon: %w[classic light map] }
      ] },
      { label: "Settings", items: [
        { label: "Location",       path: location_path,       icon: %w[classic light location-dot] },
        { label: "Connected apps", path: connected_apps_path, icon: %w[classic light plug] }
      ] },
      { label: "More", items: [
        { label: "Sidekiq", path: "/sidekiq", icon: %w[classic light layer-group], external: true }
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
end
