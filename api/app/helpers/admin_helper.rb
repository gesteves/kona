module AdminHelper
  # The id of the Republish dialog. The layout renders that dialog, and the nav item opens it.
  # ⚠️ Both sides read this constant, thus the two values cannot become different.
  REPUBLISH_DIALOG_ID = "republish-site".freeze

  # The items of the admin sidebar that are not in a group, in order. The owner uses these often,
  # thus they need no click first. Refer to #admin_nav_groups for each other item.
  #
  # This is data, thus the code for `data-drawer="close"`, for `aria-current`, and for the icons is
  # in layouts/_admin_nav_item.html.erb, one time only.
  # `external: true` marks a destination outside the Rails admin UI, which opens in a new tab.
  # `dialog:` marks an item that opens a dialog of the layout, and it has no :path.
  #
  # @return [Array<Hash>] Each item has :label, :icon, and either :path or :dialog. :icon holds the
  #   three arguments of icon_svg. An item can also have :badge and :external.
  def admin_nav_items
    [
      { label: t("admin.pages.home"), path: root_path, icon: %w[classic light house] },
      { label: t("admin.nav.republish"), dialog: REPUBLISH_DIALOG_ID, icon: %w[classic light arrows-rotate] }
    ]
  end

  # The groups of the sidebar that have a caption, in order. Each item has the same shape as in
  # #admin_nav_items.
  #
  # The groups come from the purpose of the page, thus a group with one item is correct. Tools is
  # for a page that makes something, Messages is for the mail of a reader, Settings is for a page
  # that you configure, and More is for a page that you operate.
  #
  # ⚠️ The group is a caption, and not a link. Thus it has no :icon.
  # ⚠️ :key gives the DOM id of the caption, and the label does not. The label is a translation,
  # thus an id from it would change with a word, and `aria-labelledby` points at that id.
  # @param quarantine_count [Integer] The number of messages in the spam quarantine. The caller
  #   gives it, because a helper here uses only its arguments.
  # @return [Array<Hash>] Each group has :key, :label, and :items.
  def admin_nav_groups(quarantine_count: 0)
    [
      { key: "tools", label: t("admin.nav.groups.tools"), items: [
        { label: t("admin.pages.contentful_uploads"), path: contentful_uploads_path, icon: %w[classic light images] },
        { label: t("admin.pages.course_maps"),        path: course_maps_path,        icon: %w[classic light map] },
        { label: t("admin.pages.social"),             path: social_path,             icon: %w[classic light paper-plane] }
      ] },
      { key: "messages", label: t("admin.nav.groups.messages"), items: [
        { label: t("admin.pages.spam"), path: spam_path, icon: %w[classic light envelopes-bulk],
          badge: quarantine_count.to_i.positive? ? quarantine_count.to_i : nil }
      ] },
      { key: "settings", label: t("admin.nav.groups.settings"), items: [
        { label: t("admin.pages.location"),       path: location_path,       icon: %w[classic light location-dot] },
        { label: t("admin.pages.connected_apps"), path: connected_apps_path, icon: %w[classic light plug] }
      ] },
      { key: "more", label: t("admin.nav.groups.more"), items: [
        { label: t("admin.pages.sidekiq"), path: "/sidekiq", icon: %w[classic light layer-group], external: true }
      ] }
    ]
  end

  # The words that a Stimulus controller renders, as JSON for a `data-admin-i18n` attribute.
  #
  # ⚠️ JavaScript cannot read config/locales/en.yml. Thus the server reads the locale file and the
  # browser reads this attribute, through app/javascript/lib/i18n.js.
  #
  # ⚠️ It is a plain `data-` attribute and not a Stimulus value. A value arrives through a
  # MutationObserver, thus it is not synchronous, and a controller reads this table at `connect()`.
  #
  # @param scope [String] The translation scope of the words of that controller. A scope with no
  #   key of its own gives the nested scopes alone.
  # @param nested [Hash{Symbol=>String}] A name, and one more scope to put below it. For example,
  #   the Location page carries `admin.location.state`, which the presenter also reads.
  def admin_i18n_data(scope, **nested)
    t(scope, default: {}).merge(nested.transform_values { |other| t(other) }).to_json
  end

  # Tells if a nav item points at the page that the code renders.
  #
  # ⚠️ The match is exact, on purpose. A match on the start of the path would mark "Home", which is
  # `/`, on each page in the admin. An external item never matches, because it opens in its own tab.
  def admin_nav_current?(path)
    request.path == path
  end
end
