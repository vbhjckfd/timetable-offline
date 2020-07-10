stops = [696]
stops.each do |stop|

    #url = "https://offline.lad.lviv.ua/#{stop}"
    url = "http://localhost:4567/#{stop}"
    file_path = "/Users/mholyak/Downloads/sticker-svg/#{stop}.pdf"
    #tiff_file_path = "/Users/mholyak/Downloads/stickers/#{stop}.tiff"
    #p url
    #p file_path
    %x(wkhtmltopdf  --page-height 4134px --page-width 5906px -B 0 -L 0 -R 0 -T 0  "#{url}" "#{file_path}")

end