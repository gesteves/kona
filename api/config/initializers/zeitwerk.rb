# The folders below app/services/ group the services by feature, and they are not namespaces: the
# class in app/services/social/bluesky.rb is `Bluesky`, and not `Social::Bluesky`.
#
# ⚠️ A new folder needs an entry here. Without it, Zeitwerk expects each file in that folder to
# define a constant below a module with the name of the folder, and the boot fails.
# `concerns/` is absent because Rails already loads it as a root, and
# `activity/activity_description/` is a true namespace (`ActivityDescription`).
folders = %w[activity articles contact contentful icons location maps photos shared social weather]

Rails.autoloaders.main.collapse(folders.map { |folder| Rails.root.join("app/services", folder) })
