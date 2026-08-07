require 'spec_helper'

RSpec.describe App do
  def app
    App
  end

  # Stop 80 is a real production stop and is present in ENG_NAMES
  # ("Stryiskyi market"), so the eng-name fallback has something to find.
  STOP_CODE = '80'
  # End stop 2 is likewise real, and in ENG_NAMES as "Staryi Rynok square".
  END_STOP_CODE = 2
  API_STOP_URL = "#{API_BASE}/stops/#{STOP_CODE}/static"

  def stub_stop(body:, status: 200)
    stub_request(:get, API_STOP_URL)
      .to_return(status: status, body: body, headers: { 'Content-Type' => 'application/json' })
  end

  def valid_body(transfers: nil, **extra)
    transfers ||= [
      { 'route' => '14', 'vehicle_type' => 'tram', 'end_stop_code' => END_STOP_CODE }
    ]
    { 'name' => 'Стрийський ринок', 'code' => STOP_CODE.to_i, 'transfers' => transfers }
      .merge(extra.transform_keys(&:to_s))
      .to_json
  end

  # ── GET /:code ──────────────────────────────────────────────────────────────

  describe 'GET /:code' do
    context 'with a valid stop' do
      before { stub_stop(body: valid_body) }

      it 'returns 200' do
        get "/#{STOP_CODE}"
        expect(last_response.status).to eq(200)
      end

      it 'returns SVG content type' do
        get "/#{STOP_CODE}"
        expect(last_response.content_type).to include('image/svg+xml')
      end

      it 'sets X-Robots-Tag: noindex, nofollow' do
        get "/#{STOP_CODE}"
        expect(last_response.headers['X-Robots-Tag']).to eq('noindex, nofollow')
      end

      # The query params make a stale sticker easy to hit, and Cloudflare's
      # bypass rule lives outside this repo.
      it 'sets Cache-Control: no-store' do
        get "/#{STOP_CODE}"
        expect(last_response.headers['Cache-Control']).to include('no-store')
      end

      it 'renders an SVG document' do
        get "/#{STOP_CODE}"
        expect(last_response.body).to include('<svg')
        expect(last_response.body).to include('</svg>')
      end

      it 'includes the stop code in the SVG body' do
        get "/#{STOP_CODE}"
        expect(last_response.body).to include(">#{STOP_CODE}</tspan>")
      end
    end

    context 'layout-3: one type with ≤3 routes' do
      before do
        stub_stop(body: valid_body(transfers: [
          { 'route' => '3', 'vehicle_type' => 'tram', 'end_stop_code' => END_STOP_CODE }
        ]))
      end

      it 'returns 200 and renders without error' do
        get "/#{STOP_CODE}"
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include('<svg')
      end
    end

    context 'layout-8: two types within capacity' do
      before do
        stub_stop(body: valid_body(transfers: [
          { 'route' => '3',  'vehicle_type' => 'tram', 'end_stop_code' => END_STOP_CODE },
          { 'route' => '5',  'vehicle_type' => 'tram', 'end_stop_code' => 2 },
          { 'route' => '32', 'vehicle_type' => 'bus',  'end_stop_code' => 3 },
          { 'route' => '14', 'vehicle_type' => 'bus',  'end_stop_code' => 4 },
        ]))
      end

      it 'returns 200 and renders without error' do
        get "/#{STOP_CODE}"
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include('<svg')
      end
    end

    context 'API "trolleybus" vehicle_type (real payload for stops 80/81)' do
      before do
        stub_stop(body: valid_body(transfers: [
          { 'route' => 'А03', 'vehicle_type' => 'bus',        'end_stop_code' => 320 },
          { 'route' => 'А18', 'vehicle_type' => 'bus',        'end_stop_code' => 177 },
          { 'route' => 'А57', 'vehicle_type' => 'bus',        'end_stop_code' => 417 },
          { 'route' => 'Т25', 'vehicle_type' => 'trolleybus', 'end_stop_code' => 62 },
        ]))
      end

      it 'returns 200 and renders without error' do
        get "/#{STOP_CODE}"
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include('<svg')
        expect(last_response.body).to include('/icons/t25.svg')
      end
    end

    context 'layout-28: many routes across multiple types' do
      before do
        bus_routes = (10..23).map { |n| { 'route' => n.to_s, 'vehicle_type' => 'bus', 'end_stop_code' => END_STOP_CODE } }
        stub_stop(body: valid_body(transfers: bus_routes + [
          { 'route' => '3',  'vehicle_type' => 'tram', 'end_stop_code' => 2 },
          { 'route' => '34', 'vehicle_type' => 'trol', 'end_stop_code' => 3 },
        ]))
      end

      it 'returns 200 and renders without error' do
        get "/#{STOP_CODE}"
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include('<svg')
      end
    end

    context 'layout-28: 22 bus routes (needs a 4th grid row)' do
      before do
        stub_stop(body: valid_body(transfers: (1..22).map do |n|
          { 'route' => n.to_s, 'vehicle_type' => 'bus', 'end_stop_code' => END_STOP_CODE }
        end))
      end

      it 'returns 200 and renders without error' do
        get "/#{STOP_CODE}"
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include('<svg')
      end

      it 'renders all 22 route icons' do
        get "/#{STOP_CODE}"
        # Routes 1-6 normalise to 1a-6a, the rest keep their bare number.
        expect(last_response.body.scan(%r{/icons/\d+[a-z]?\.svg}).length).to eq(22)
      end

      it 'places the 22nd route on a 4th row clear of the QR block at y 3172' do
        get "/#{STOP_CODE}"
        # 4th row top = 3378.22 - 295.28, rendered as a float.
        expect(last_response.body).to match(/y="3082\.9\d*"/)
      end
    end

    context 'error handling' do
      it 'returns 400 when the API returns 400' do
        stub_request(:get, "#{API_BASE}/stops/abc/static").to_return(status: 400, body: '')
        get '/abc'
        expect(last_response.status).to eq(400)
      end

      it 'returns 503 when the API returns 500' do
        stub_stop(body: 'upstream boom', status: 500)
        get "/#{STOP_CODE}"
        expect(last_response.status).to eq(503)
      end

      it 'returns 503 when the API connection times out' do
        stub_request(:get, API_STOP_URL).to_timeout
        get "/#{STOP_CODE}"
        expect(last_response.status).to eq(503)
      end

      it 'returns 404 when the API returns 404' do
        stub_request(:get, "#{API_BASE}/stops/9999/static").to_return(status: 404, body: '')
        get '/9999'
        expect(last_response.status).to eq(404)
      end

      it 'returns 503 when the API response is not valid JSON' do
        stub_stop(body: 'not json at all')
        get "/#{STOP_CODE}"
        expect(last_response.status).to eq(503)
      end
    end

    context 'stop name cleaning' do
      it 'strips known suburb prefixes' do
        body = { 'name' => 'Рудне, Центр', 'code' => STOP_CODE.to_i, 'transfers' => [
          { 'route' => '14', 'vehicle_type' => 'tram', 'end_stop_code' => END_STOP_CODE }
        ] }.to_json
        stub_stop(body: body)
        get "/#{STOP_CODE}"
        expect(last_response.body).not_to include('Рудне,')
        expect(last_response.body).to include('Центр')
      end
    end
  end

  # ── ?add / ?remove ──────────────────────────────────────────────────────────

  describe 'route overrides' do
    before do
      stub_stop(body: valid_body(transfers: [
        { 'route' => 'А46', 'vehicle_type' => 'bus', 'end_stop_code' => END_STOP_CODE },
        { 'route' => 'Т03', 'vehicle_type' => 'trolleybus', 'end_stop_code' => END_STOP_CODE },
      ]))
    end

    it 'drops a removed route from the sticker' do
      get "/#{STOP_CODE}?remove=T03"
      expect(last_response.body).to include('/icons/46.svg')
      expect(last_response.body).not_to include('/icons/t3.svg')
    end

    it 'draws an added route on the sticker' do
      get "/#{STOP_CODE}?add=T02"
      expect(last_response.body).to include('/icons/t2.svg')
    end

    it 'applies both params at once' do
      get "/#{STOP_CODE}?add=A47,T02&remove=T03,A46"
      expect(last_response.body).to include('/icons/47a.svg')
      expect(last_response.body).to include('/icons/t2.svg')
      expect(last_response.body).not_to include('/icons/46.svg')
      expect(last_response.body).not_to include('/icons/t3.svg')
    end

    it 'applies the overrides to the schema too' do
      get "/#{STOP_CODE}/schema?add=T02&remove=T03"
      expect(last_response.body).to include('/icons/t2.svg')
      expect(last_response.body).not_to include('/icons/t3.svg')
    end

    it 'renders a stop stripped down to a single route' do
      get "/#{STOP_CODE}?remove=A46"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include('<svg')
    end

    it 'ignores a route name that is not a plain badge' do
      get "/#{STOP_CODE}?add=%2E%2E%2F%2E%2E%2Fsecret"
      expect(last_response.status).to eq(200)
      expect(last_response.body).not_to include('secret')
    end

    it 'keeps only the listed routes' do
      get "/#{STOP_CODE}?only=T03"
      expect(last_response.body).to include('/icons/t3.svg')
      expect(last_response.body).not_to include('/icons/46.svg')
    end

    it 'draws a listed route the stop does not serve' do
      get "/#{STOP_CODE}?only=A46,T02"
      expect(last_response.body).to include('/icons/46.svg')
      expect(last_response.body).to include('/icons/t2.svg')
      expect(last_response.body).not_to include('/icons/t3.svg')
    end

    it 'applies only alongside add on the schema' do
      get "/#{STOP_CODE}/schema?only=A46&add=T02"
      expect(last_response.body).to include('/icons/46.svg')
      expect(last_response.body).to include('/icons/t2.svg')
      expect(last_response.body).not_to include('/icons/t3.svg')
    end
  end

  # ── GET /:code/schema ───────────────────────────────────────────────────────

  describe 'GET /:code/schema' do
    context 'with a valid stop' do
      before { stub_stop(body: valid_body) }

      it 'returns 200' do
        get "/#{STOP_CODE}/schema"
        expect(last_response.status).to eq(200)
      end

      it 'returns SVG content type' do
        get "/#{STOP_CODE}/schema"
        expect(last_response.content_type).to include('image/svg+xml')
      end

      it 'sets X-Robots-Tag: noindex, nofollow' do
        get "/#{STOP_CODE}/schema"
        expect(last_response.headers['X-Robots-Tag']).to eq('noindex, nofollow')
      end

      it 'sets Cache-Control: no-store' do
        get "/#{STOP_CODE}/schema"
        expect(last_response.headers['Cache-Control']).to include('no-store')
      end

      it 'renders an SVG document' do
        get "/#{STOP_CODE}/schema"
        expect(last_response.body).to include('<svg')
        expect(last_response.body).to include('</svg>')
      end

      it 'includes the English stop name' do
        get "/#{STOP_CODE}/schema"
        expect(last_response.body).to include('Stryiskyi market')
      end
    end

    context 'English stop name resolution' do
      # 182 of the API's 993 stops are absent from eng_names.rb; this used to
      # raise NoMethodError on nil and 500.
      it 'renders a stop that is in neither the API nor eng_names.rb' do
        stub_request(:get, "#{API_BASE}/stops/999999/static")
          .to_return(status: 200, body: valid_body, headers: { 'Content-Type' => 'application/json' })

        get '/999999/schema'
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include('<svg')
      end

      it 'uses the API eng_name for a stop missing from eng_names.rb' do
        stub_request(:get, "#{API_BASE}/stops/999999/static")
          .to_return(status: 200, body: valid_body(eng_name: 'Brand New Stop'),
                     headers: { 'Content-Type' => 'application/json' })

        get '/999999/schema'
        expect(last_response.body).to include('Brand New Stop')
      end

      # eng_names.rb has stop 80 as "Stryiskyi market"; the API wins.
      it 'prefers the API eng_name over the stale eng_names.rb entry' do
        stub_stop(body: valid_body(
          eng_name: 'Lem Square',
          transfers: [{ 'route' => '14', 'vehicle_type' => 'tram', 'end_stop_code' => 999999 }]
        ))

        get "/#{STOP_CODE}/schema"
        expect(last_response.body).to include('Lem Square')
        expect(last_response.body).not_to include('Stryiskyi market')
      end

      it 'prefers the API end_stop_eng_name over the stale eng_names.rb entry' do
        stub_stop(body: valid_body(transfers: [
          { 'route' => '14', 'vehicle_type' => 'tram', 'end_stop_code' => END_STOP_CODE,
            'end_stop_eng_name' => 'Renamed Terminus' }
        ]))

        get "/#{STOP_CODE}/schema"
        expect(last_response.body).to include('Renamed Terminus')
      end
    end

    context 'error handling' do
      it 'returns 400 when the API returns 400' do
        stub_request(:get, "#{API_BASE}/stops/abc/static").to_return(status: 400, body: '')
        get '/abc/schema'
        expect(last_response.status).to eq(400)
      end

      it 'returns 404 when the API returns 404' do
        stub_request(:get, "#{API_BASE}/stops/9999/static").to_return(status: 404, body: '')
        get '/9999/schema'
        expect(last_response.status).to eq(404)
      end

      it 'returns 503 when the API response is not valid JSON' do
        stub_stop(body: 'not json')
        get "/#{STOP_CODE}/schema"
        expect(last_response.status).to eq(503)
      end
    end
  end

  # ── upstream request construction ───────────────────────────────────────────

  describe 'upstream URL construction' do
    it 'percent-encodes the stop code instead of interpolating it raw' do
      escaped = stub_request(:get, "#{API_BASE}/stops/%D0%90/static")
                  .to_return(status: 404, body: '')

      get '/%D0%90' # Cyrillic А

      expect(last_response.status).to eq(404)
      expect(escaped).to have_been_requested
    end

    # Sinatra 4 mounts Rack::Protection::PathTraversal, which normalises the
    # path before routing, so ../ never reaches params. url_encode is the second
    # layer, in case that middleware is ever dropped.
    it 'does not let an encoded ../ reach the upstream path' do
      stub_request(:get, %r{#{API_BASE}/stops/.*/static}).to_return(status: 404, body: '')

      get '/..%2F..%2Fadmin'

      expect(WebMock).not_to have_requested(:get, %r{/stops/\.\.})
    end
  end

  # ── SVG well-formedness ─────────────────────────────────────────────────────

  describe 'SVG output' do
    before do
      stub_stop(body: valid_body(transfers: (1..12).map do |n|
        { 'route' => n.to_s, 'vehicle_type' => 'bus', 'end_stop_code' => END_STOP_CODE }
      end))
    end

    it 'emits no empty transform values' do
      get "/#{STOP_CODE}"
      expect(last_response.body).not_to include('translate(0, )')
    end
  end

  # ── QR code generation ──────────────────────────────────────────────────────

  describe 'QR code generation' do
    before { stub_stop(body: valid_body) }

    it 'embeds an SVG QR code in the layout' do
      get "/#{STOP_CODE}"
      expect(last_response.body).to include('lad.lviv.ua')
    end
  end
end
