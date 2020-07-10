stops = [60, 636]
stops.each do |stop|

    #url = "https://offline.lad.lviv.ua/#{stop}"
    url = "http://localhost:4567/#{stop}"
    file_path = "/Users/mholyak/Downloads/sticker-svg/#{stop}.pdf"
    #tiff_file_path = "/Users/mholyak/Downloads/stickers/#{stop}.tiff"
    #p url
    #p file_path
    %x(wkhtmltopdf --page-height 350mm --page-width 500mm -B 0 -L 0 -R 0 -T 0 --zoom 0.5 "#{url}" "#{file_path}")

end