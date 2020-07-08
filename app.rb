require 'sinatra/base'
require 'faraday'
require 'rqrcode'

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
    name = name.gsub(/[та]/, 'т' => 't', 'а' => 'a')
    name = name.gsub('a0', 'a')
    name = name.gsub('t0', 't')
    name = name[1..-1] if name.chr == "a"
    t['route_normalized'] = name

    transfers[type] << t
  end
  transfers = transfers.delete_if { |k, v| v.empty? }
end

class App < Sinatra::Base
  get '/:code' do
    stop_code = params['code']
    api_url = ENV['API_URL'] || 'https://api.lad.lviv.ua'

    response = Faraday.get "#{api_url}/stops/#{stop_code}"

    halt response.status, "Код зупинки має бути числом, на кшталт 128" if response.status == 400
    halt response.status, "Неправильний код зупинки" if response.status == 404

    begin
      data = JSON.parse(response.body)
    rescue JSON::ParserError => e
      data = nil
    end
    halt 503 if data.nil?

    transfers = get_transfers(data)

    qrcode = RQRCode::QRCode.new("https://lad.lviv.ua/#{stop_code}")

    local_variables = {}

    n = detect_layout(transfers)
    local_variables = {}

    if (3 == n)

    elsif (8 == n)

    else

    end

    svg = qrcode.as_svg(
      offset: 0,
      color: '000',
      shape_rendering: 'crispEdges',
      module_size: 6,
      standalone: true
    )

    erb "layout-#{n}".to_sym, :locals => {
      data: data,
      transfers: transfers,
      qrcode: svg,
  }.merge(local_variables)
  end
end

App.run!
