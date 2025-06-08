require_relative '../utils/static_map'
namespace :maps do
  # Loops through the GPX files stored in the StaticMap::GPX_FOLDER folder (data/maps/gpx),
  # generates a map for each as a static PNG image, and saves it to the StaticMap::IMAGES_FOLDER folder (data/mapbox/images).
  # It uses the Mapbox Static API to generate the map image based on the bounding box of the GPX file,
  # but the GPX files must be uploaded manually to Mapbox Studio as tilesets first.
  # @todo Automate uploading the GPX files to Mapbox.
  desc 'Generate static map images from GPX files'
  task generate: :environment do
    gpx_files = Dir.glob(File.join(StaticMap::GPX_FOLDER, '*.gpx'))
    
    if gpx_files.empty?
      puts "⚠️ No GPX files found in #{StaticMap::GPX_FOLDER}"
      next
    end

    gpx_files.each do |gpx_file|
      options = {
        reverse_markers: ENV['REVERSE_MARKERS'].present?,
        padding: ENV['PADDING'],
        height: ENV['HEIGHT'],
        min_km: ENV['MIN_KM'],
        tileset_id: ENV['TILESET_ID'],
        dnf: ENV['DNF'].present?
      }.compact
      map = StaticMap.new(gpx_file, options)
      
      unless map.tileset_id
        print "Enter the Mapbox tileset ID for #{map.activity_title}, or press Enter to skip: "
        map.tileset_id = STDIN.gets.chomp
        if map.tileset_id.empty?
          puts "⏭️  Skipping #{map.activity_title}.\n\n"
          next
        end
      end

      begin
        map.generate_image!
      rescue => e
        puts "❎ Error generating map for #{map.activity_title}: #{e.message}"
        next
      end   
    end
    puts "✅ Map generation complete!"
  end

  desc 'Show help information for map generation tasks'
  task help: :environment do
    puts <<~HELP
      Map Generation Help
      ==================

      This rake task generates static map images from GPX files using Mapbox's Static API.

      Prerequisites:
      -------------
      1. A Mapbox account and access token (set MAPBOX_ACCESS_TOKEN environment variable)
      2. GPX files uploaded to Mapbox Studio as tilesets
      3. GPX files placed in #{StaticMap::GPX_FOLDER}

      Usage:
      ------
      rake maps:generate [options]

      Options:
      --------
      TILESET_ID=<id>     Mapbox tileset ID for the GPX file. If not provided, you'll be prompted for each file.
      REVERSE_MARKERS     Reverse the start/end markers (default: false)
      PADDING=<value>     Padding around the map in pixels. Can be:
                          - Single value (e.g., 50) for all sides
                          - Two values (e.g., 50,100) for top/bottom, left/right
                          - Three values (e.g., 50,100,75) for top, left/right, bottom
                          - Four values (e.g., 50,100,75,25) for top, right, bottom, left
                          Default: 50
      HEIGHT=<value>      Custom height for the map in pixels (default: calculated based on aspect ratio)
      MIN_KM=<value>      Minimum width and height of the map's viewable area in kilometers (default: 1)
      DNF                 Mark the activity as Did Not Finish (changes end marker icon)

      Example:
      --------
      rake maps:generate TILESET_ID=your-tileset-id PADDING=100 MIN_KM=2

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
