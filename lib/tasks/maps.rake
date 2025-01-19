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
end
