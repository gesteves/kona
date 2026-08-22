module AdminHelper
  # The items of the admin sidebar that are not in a group, in the order that they appear. The owner
  # uses these two often, thus they need no click first. Each other item is in a group. Refer to
  # #admin_nav_groups.
  #
  # This is data, and not markup that a person writes. Thus the code for `data-drawer="close"`, for
  # `aria-current`, and for the icons is in layouts/_admin_nav_item.html.erb, one time only.
  # `external: true` marks a destination outside the Rails admin UI, which opens in a new tab.
  #
  # @param quarantine_count [Integer] The number of messages in the spam quarantine. The caller
  #   gives it, and this method does not read an instance variable. Thus this method uses only its
  #   arguments, as each other helper here does.
  # @return [Array<Hash>] Each item has :label, :path, and :icon, which are the three arguments of
  #   icon_svg. An item can also have :badge and :external.
  def admin_nav_items(quarantine_count: 0)
    [
      { label: "Home", path: root_path, icon: %w[classic light house] },
      { label: "Spam", path: spam_path, icon: %w[classic light envelopes-bulk],
        badge: quarantine_count.to_i.positive? ? quarantine_count.to_i : nil }
    ]
  end

  # The groups of the sidebar that have a caption, in the order that they appear. Each item has the
  # same shape as in #admin_nav_items.
  #
  # A group with one item is still correct: the groups come from *the purpose of the page*. Tools is
  # for a page that makes something, Settings is for a page that you configure, and More is for a
  # page that you operate. Thus a new page has a clear place, and one flat list does not become
  # longer.
  #
  # ⚠️ The group is a caption, and not a link. Thus it has no :icon. Each of its items has one, in
  # the same column as the items above that are not in a group.
  # @return [Array<Hash>] Each group has :label and :items.
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

  # Tells if a nav item points at the page that the code renders.
  #
  # ⚠️ The match is exact, on purpose. A match on the start of the path would mark "Home", which is
  # now `/`, on each page in the admin. An external item never matches, because it opens in its own
  # tab.
  # @param path [String]
  # @return [Boolean]
  def admin_nav_current?(path)
    request.path == path
  end
end
