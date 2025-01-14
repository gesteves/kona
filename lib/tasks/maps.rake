require_relative '../utils/static_map'
namespace :maps do
  desc 'Generate static map images from GPX files in the data/maps/gpx folder'
  task generate: :environment do
    Dir.glob(File.join(StaticMap::GPX_FOLDER, '*.gpx')).each do |gpx_file|
      options = {
        reverse_markers: ENV['REVERSE_MARKERS'].present?,
        padding: ENV['PADDING'],
        max_height: ENV['MAX_HEIGHT'],
        min_size: ENV['MIN_SIZE'],
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
    puts "✅ All maps generated!"
  end
end
