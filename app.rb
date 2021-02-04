require 'sinatra/base'
require 'faraday'
require 'rqrcode'
require 'base64'
require "active_support/all"

def detect_layout(transfers)
  routeTypesCount = transfers.keys.length
  routesCount = transfers.values.flatten.length

  if (routeTypesCount == 1 && routesCount <= 3)
    n = 3
  elsif ([1, 2].include?(routeTypesCount) && routesCount <= 8 && transfers.values.all? {|rs| rs.length <= 4 })
    n = 8
  else
    n = 28
  end
  n
end

def get_transfers(data)
  transfers = {
    bus: [],
    tram: [],
    trol: [],
    night: [],
  }

  data['transfers'].each do |t|
    if t['route'].start_with? 'Н'
      type = :night
    else
      type = t['vehicle_type'].to_sym
    end

    name = t['route'].downcase
    name = name.gsub(/[тан]/, 'т' => 't', 'а' => 'a', 'н' => 'n')
    name = name.gsub('a0', 'a')
    name = name.gsub('t0', 't')
    name = name.gsub('n0', 'n')
    name = name[1..-1] if name.chr == "a"
    name = 'airport' if name == "еропорt"
    name = name + "a" if ["1", "2", "3", "4", "5", "6", "36", "47"].include? name
    t['route_normalized'] = name

    transfers[type] << t
  end
  transfers = transfers.delete_if { |k, v| v.empty? }
end

class App < Sinatra::Base

  get '/:code/schema' do
    stop_code = params['code']
    api_url = ENV['API_URL'] || 'https://api.lad.lviv.ua'

    response = Faraday.get "#{api_url}/stops/#{stop_code}/static"

    halt response.status, "Код зупинки має бути числом, на кшталт 128" if response.status == 400
    halt response.status, "Неправильний код зупинки" if response.status == 404

    begin
      data = JSON.parse(response.body)
    rescue JSON::ParserError => e
      data = nil
    end
    halt 503 if data.nil?

    transfers = get_transfers(data)

    data['name_en'] = 'ENG_' << data['name']

    erb "scheme".to_sym,
    :locals => {
      data: data,
      transfers: transfers
    },
    content_type: 'image/svg+xml'
  end

  # get '/:code.pdf' do
  #   require 'pdfkit'


  #   stop_code = params['code']

  #   kit = PDFKit.new("http://localhost:4567/#{stop_code}", {
  #       'page-height' => '350mm',
  #       'page-width'=> '500mm',
  #       'margin-top' => 0,
  #       'margin-right' => 0,
  #       'margin-bottom' => 0,
  #       'margin-left' => 0,
  #       'zoom' => 0.5,
  #   })

  #   pdf = kit.to_pdf
  #   if (params[:download])
  #     return 'Not implemented'
  #     io = StringIO.new(pdf)
  #     send_file(io, :disposition => 'attachment', :filename => "#{stop_code}.pdf")
  #   end

  #   content_type 'application/pdf'
  #   pdf
  # end

  get '/:code' do
    stop_code = params['code']
    api_url = ENV['API_URL'] || 'https://api.lad.lviv.ua'

    response = Faraday.get "#{api_url}/stops/#{stop_code}/static"

    halt response.status, "Код зупинки має бути числом, на кшталт 128" if response.status == 400
    halt response.status, "Неправильний код зупинки" if response.status == 404

    begin
      data = JSON.parse(response.body)
    rescue JSON::ParserError => e
      data = nil
    end
    halt 503 if data.nil?

    transfers = get_transfers(data)

    n = detect_layout(transfers)

    qrcode = RQRCode::QRCode.new("https://lad.lviv.ua/#{stop_code}")
    svg = qrcode.as_svg(
      offset: 0,
      color: '000',
      shape_rendering: 'crispEdges',
      module_size: 6,
      standalone: true
    ).to_s.sub('<?xml version="1.0" standalone="yes"?>', '')

    erb "layout-#{n}".to_sym,
    :locals => {
      data: data,
      transfers: transfers,
      qrcode: svg,
    },
    content_type: 'image/svg+xml'
  end

end

App.run!
