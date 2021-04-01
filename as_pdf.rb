require 'parallel'
require 'ruby-progressbar'
require 'json'

all_stops_raw = `curl -s https://api.lad.lviv.ua/stops.json`
all_stops_hash = JSON.parse all_stops_raw

stops = all_stops_hash.map {|s| s['code']}
#stops = [40]

# filtered_stops = stops.select {|code|
#     stop_data = JSON.parse `curl -s https://api.lad.lviv.ua/stops/#{code}/static`
#     0 == stop_data["transfers"].length
# }

# puts(filtered_stops);

Parallel.each_with_index(stops, in_threads: 5, progress: "Generating") do |stop, index|
    #url = "https://offline.lad.lviv.ua/#{stop}"
    url = "http://localhost:4567/#{stop}"
    file_path = "/Users/mholyak/Downloads/sticker-svg-qr/#{stop}.pdf"
    #tiff_file_path = "/Users/mholyak/Downloads/stickers/#{stop}.tiff"
    #p url
    #p file_path

    if !File.exist?(file_path) || ARGV[0]
        result = system("wkhtmltopdf -q --page-height 350mm --page-width 500mm -B 0 -L 0 -R 0 -T 0 --zoom 0.5 --disable-external-links '#{url}' '#{file_path}'")
        #result = system("wkhtmltopdf -q --page-height 720mm --page-width 838mm -B 0 -L 0 -R 0 -T 0 --zoom 0.5 --disable-external-links '#{url}' '#{file_path}'")
        puts url if (!result)
    end
end