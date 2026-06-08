namespace :maps do
  # Loops through the GPX files stored in the StaticMap::GPX_FOLDER folder (data/maps/gpx),
  # generates a map for each as a static PNG image, and saves it to the StaticMap::IMAGES_FOLDER folder (data/maps/images).
  # Each GPX file is uploaded to Mapbox automatically as a private vector tileset (via the
  # Mapbox Tiling Service), then rendered with the Mapbox Static API based on the bounding
  # box of the GPX file. Pass TILESET_ID to skip the upload and reuse an existing tileset.
  desc 'Generate static map images from GPX files'
  task generate: :environment do
    gpx_files = Dir.glob(File.join(StaticMap::GPX_FOLDER, '*.gpx'))

    if gpx_files.empty?
      puts "⚠️ No GPX files found in #{StaticMap::GPX_FOLDER}"
      next
    end

    # These options apply to every file, so build them once.
    options = {
      reverse_markers: ENV['REVERSE_MARKERS'].present?,
      padding: ENV['PADDING'],
      height: ENV['HEIGHT'],
      min_km: ENV['MIN_KM'],
      dnf: ENV['DNF'].present?,
      force_upload: ENV['FORCE_UPLOAD'].present?
    }.compact

    # By default each GPX file is uploaded to Mapbox automatically. A tileset ID
    # identifies a single track, so the TILESET_ID override (skip upload, reuse an
    # existing tileset) only applies when there's exactly one GPX file.
    options[:tileset_id] = ENV['TILESET_ID'] if gpx_files.one? && ENV['TILESET_ID'].present?

    generated = failed = 0

    gpx_files.each do |gpx_file|
      map = StaticMap.new(gpx_file, options)

      begin
        map.generate_image!
        generated += 1
      rescue => e
        puts "❎ Error generating map for #{map.activity_title}: #{e.message}"
        failed += 1
        next
      end
    end

    puts "✅ Map generation complete! #{generated} generated, #{failed} failed."
  end

  desc 'Show help information for map generation tasks'
  task help: :environment do
    puts <<~HELP
      Map Generation Help
      ==================

      This rake task generates static map images from GPX files. Each GPX file is uploaded
      to Mapbox automatically as a private vector tileset (Mapbox Tiling Service), then
      rendered with Mapbox's Static API.

      Prerequisites:
      -------------
      1. A Mapbox account, with:
         - MAPBOX_ACCESS_TOKEN: token used to render the static map image.
         - MAPBOX_USERNAME: your Mapbox account username (required for the upload).
         - MAPBOX_SECRET_TOKEN: a secret token with the `tilesets:write` and
           `tilesets:read` scopes (required for the upload; also used to render so it
           can read the private tilesets it creates).
      2. GPX files placed in #{StaticMap::GPX_FOLDER}

      Usage:
      ------
      rake maps:generate [options]

      Options:
      --------
      TILESET_ID=<id>     Skip the upload and render from an existing Mapbox tileset
                          (full "username.tileset" form). Only applies to a single GPX file.
      SOURCE_LAYER=<name> Source-layer to read when using TILESET_ID (default: tracks).
      FORCE_UPLOAD        Re-upload the GPX even if its tileset already exists. Use this
                          when the GPX itself changed; tweaking the image settings below
                          reuses the existing tileset automatically (no re-upload).
      REVERSE_MARKERS     Reverse the start/end markers (default: false)
      PADDING=<value>     Padding around the map in pixels. Can be:
                          - Single value (e.g., 50) for all sides
                          - Two values (e.g., 50,100) for top/bottom, left/right
                          - Three values (e.g., 50,100,75) for top, left/right, bottom
                          - Four values (e.g., 50,100,75,25) for top, right, bottom, left
                          Default: 50
      HEIGHT=<value>      Custom height for the map in pixels (default: calculated based on aspect ratio)
      MIN_KM=<value>      Kilometers of map to add around the track, in CSS-style
                          "top,right,bottom,left" shorthand (like PADDING but in km):
                          - Single value (e.g., 2) for all sides
                          - Two values (e.g., 2,1) for top/bottom, left/right
                          - Three values (e.g., 2,1,0) for top, left/right, bottom
                          - Four values (e.g., 2,1,0,1) for top, right, bottom, left
                          Default: 0. Example: MIN_KM=2,0,0,0 adds 2 km above the track.
      DNF                 Mark the activity as Did Not Finish (changes end marker icon)

      Example:
      --------
      rake maps:generate PADDING=100 MIN_KM=2

      Output:
      -------
      Generated maps are saved to: #{StaticMap::IMAGES_FOLDER}
      File names are based on the activity title from the GPX file

      Notes:
      ------
      - The map style can be customized by setting MAPBOX_STYLE_URL environment variable
        (default: mapbox://styles/mapbox/outdoors-v12)
      - Track color is set to ##{StaticMap::TRACK_COLOR} with #{StaticMap::TRACK_OPACITY * 100}% opacity
      - Start marker is green (#{StaticMap::START_MARKER_COLOR}), end marker is red (#{StaticMap::END_MARKER_COLOR})
      - Map width is fixed at #{StaticMap::WIDTH}px, height is calculated based on the track's aspect ratio
        (minimum: #{StaticMap::MIN_HEIGHT}px, maximum: #{StaticMap::MAX_HEIGHT}px)
    HELP
  end
end
