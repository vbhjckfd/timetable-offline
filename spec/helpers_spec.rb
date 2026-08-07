require 'spec_helper'

RSpec.describe '#detect_layout' do
  it 'returns 3 for one type with 1 route' do
    expect(detect_layout(bus: %w[r1])).to eq(3)
  end

  it 'returns 3 for one type with 3 routes' do
    expect(detect_layout(tram: %w[r1 r2 r3])).to eq(3)
  end

  it 'returns 8 for one type with 4 routes' do
    expect(detect_layout(bus: %w[r1 r2 r3 r4])).to eq(8)
  end

  it 'returns 28 for one type with 5 routes (exceeds per-type limit of 4)' do
    expect(detect_layout(bus: %w[r1 r2 r3 r4 r5])).to eq(28)
  end

  it 'returns 8 for two types each with ≤4 routes and ≤8 total' do
    expect(detect_layout(tram: %w[r1 r2 r3], bus: %w[r4 r5])).to eq(8)
  end

  it 'returns 8 for two types each with exactly 4 routes' do
    expect(detect_layout(tram: %w[r1 r2 r3 r4], bus: %w[r5 r6 r7 r8])).to eq(8)
  end

  it 'returns 28 for three types' do
    expect(detect_layout(bus: %w[r1], tram: %w[r2], trol: %w[r3])).to eq(28)
  end

  it 'returns 28 when one type exceeds 4 routes in a two-type set' do
    expect(detect_layout(bus: %w[r1 r2 r3 r4 r5], tram: %w[r6])).to eq(28)
  end

  it 'returns 28 when total routes exceed 8' do
    expect(detect_layout(bus: Array.new(9) { |i| "r#{i}" })).to eq(28)
  end
end

RSpec.describe '#get_transfers' do
  def make_transfer(route:, vehicle_type:, end_stop_code: 99)
    { 'route' => route, 'vehicle_type' => vehicle_type, 'end_stop_code' => end_stop_code }
  end

  def call(transfers_array)
    get_transfers('transfers' => transfers_array)
  end

  describe 'type categorisation' do
    it 'puts tram routes under :tram' do
      result = call([make_transfer(route: '14', vehicle_type: 'tram')])
      expect(result).to have_key(:tram)
      expect(result[:tram].first['route']).to eq('14')
    end

    it 'puts bus routes under :bus' do
      result = call([make_transfer(route: '25а', vehicle_type: 'bus')])
      expect(result).to have_key(:bus)
    end

    it 'puts trolleybus routes under :trol' do
      result = call([make_transfer(route: '3', vehicle_type: 'trol')])
      expect(result).to have_key(:trol)
    end

    it 'puts routes with the API "trolleybus" type under :trol' do
      result = call([make_transfer(route: 'Т25', vehicle_type: 'trolleybus')])
      expect(result).to have_key(:trol)
      expect(result[:trol].first['route']).to eq('Т25')
    end

    it 'falls back to :bus for an unknown vehicle_type instead of raising' do
      result = call([make_transfer(route: '99', vehicle_type: 'hovercraft')])
      expect(result).to have_key(:bus)
      expect(result[:bus].first['route']).to eq('99')
    end

    it 'puts routes starting with Н under :night regardless of vehicle_type' do
      result = call([make_transfer(route: 'Н1', vehicle_type: 'bus')])
      expect(result).to have_key(:night)
      expect(result[:night].first['route']).to eq('Н1')
    end

    it 'omits empty type keys' do
      result = call([make_transfer(route: '14', vehicle_type: 'tram')])
      expect(result.keys).to eq([:tram])
    end
  end

  describe 'route name normalisation' do
    def normalized(route, vehicle_type: 'bus')
      result = call([make_transfer(route: route, vehicle_type: vehicle_type)])
      result.values.flatten.first['route_normalized']
    end

    it 'lowercases the route name' do
      expect(normalized('14')).to eq('14')
    end

    it 'replaces Cyrillic а with Latin a' do
      expect(normalized('25а')).to eq('25a')
    end

    it 'replaces Cyrillic т with Latin t' do
      expect(normalized('3т', vehicle_type: 'bus')).to eq('3t')
    end

    it 'strips leading Cyrillic А (becomes leading Latin a, then dropped)' do
      expect(normalized('А36')).to eq('36a')
    end

    it 'appends "a" suffix to single-digit tram codes 1-6' do
      %w[1 2 3 4 5 6].each do |code|
        expect(normalized(code, vehicle_type: 'tram')).to eq("#{code}a")
      end
    end

    it 'appends "a" suffix to route 36' do
      expect(normalized('36')).to eq('36a')
    end

    it 'appends "a" suffix to route 47' do
      expect(normalized('47')).to eq('47a')
    end

    it 'does not append suffix to route 32' do
      expect(normalized('32')).to eq('32')
    end

    it 'collapses suffix а0 to a (e.g. 25а0 → 25a)' do
      expect(normalized('25а0')).to eq('25a')
    end

    it 'collapses t0 to t' do
      expect(normalized('т0', vehicle_type: 'tram')).to eq('t')
    end

    it 'normalises the airport route' do
      expect(normalized('Аеропорт')).to eq('airport')
    end
  end

  describe 'English stop name lookup' do
    it 'sets eng_end_stop_name from ENG_NAMES when code is known' do
      result = call([make_transfer(route: '3', vehicle_type: 'tram', end_stop_code: 2)])
      expect(result[:tram].first['eng_end_stop_name']).to eq('Staryi Rynok square')
    end

    it 'sets eng_end_stop_name to empty string for unknown end_stop_code' do
      result = call([make_transfer(route: '3', vehicle_type: 'tram', end_stop_code: 999999)])
      expect(result[:tram].first['eng_end_stop_name']).to eq('')
    end
  end
end

RSpec.describe '#apply_route_overrides' do
  def data(*routes)
    { 'transfers' => routes.map { |r| { 'route' => r, 'vehicle_type' => 'bus', 'end_stop_code' => 2 } } }
  end

  def routes(result)
    result['transfers'].map { |t| t['route'] }
  end

  describe 'remove' do
    it 'drops a route matched by its Latin query name' do
      result = apply_route_overrides(data('А47', 'А46'), remove: 'A47')
      expect(routes(result)).to eq(['А46'])
    end

    it 'drops several comma-separated routes' do
      result = apply_route_overrides(data('А47', 'А46', 'Т03'), remove: 'A47,T03')
      expect(routes(result)).to eq(['А46'])
    end

    it 'ignores surrounding whitespace' do
      result = apply_route_overrides(data('А47', 'А46'), remove: ' A47 , A46 ')
      expect(routes(result)).to be_empty
    end

    it 'ignores a route that does not serve the stop' do
      result = apply_route_overrides(data('А46'), remove: 'A99')
      expect(routes(result)).to eq(['А46'])
    end

    it 'leaves the list untouched when the param is absent' do
      result = apply_route_overrides(data('А46'))
      expect(routes(result)).to eq(['А46'])
    end
  end

  describe 'add' do
    it 'appends a route the API does not list' do
      result = apply_route_overrides(data('А46'), add: 'A47')
      expect(routes(result)).to eq(['А46', 'A47'])
    end

    it 'appends several comma-separated routes' do
      result = apply_route_overrides(data('А46'), add: 'A47,T02')
      expect(routes(result)).to eq(['А46', 'A47', 'T02'])
    end

    it 'does not duplicate a route the stop already has' do
      result = apply_route_overrides(data('А46'), add: 'A46')
      expect(routes(result)).to eq(['А46'])
    end

    it 'does not duplicate a route added twice in one param' do
      result = apply_route_overrides(data, add: 'A47,А47')
      expect(routes(result)).to eq(['A47'])
    end

    it 'infers trolleybus from a T prefix' do
      result = apply_route_overrides(data, add: 'T02')
      expect(result['transfers'].first['vehicle_type']).to eq('trol')
    end

    it 'infers bus from an A prefix' do
      result = apply_route_overrides(data, add: 'A47')
      expect(result['transfers'].first['vehicle_type']).to eq('bus')
    end

    it 'infers tram from a bare number' do
      result = apply_route_overrides(data, add: '8')
      expect(result['transfers'].first['vehicle_type']).to eq('tram')
    end

    it 'buckets an N-prefixed route as night' do
      result = apply_route_overrides(data, add: 'N1')
      expect(get_transfers(result)).to have_key(:night)
    end

    it 'gives the added route a blank destination' do
      transfer = apply_route_overrides(data, add: 'A47')['transfers'].first
      expect(transfer['end_stop_name']).to eq('')
      expect(get_transfers('transfers' => [transfer])[:bus].first['eng_end_stop_name']).to eq('')
    end

    # route_normalized lands in an xlink:href, so a name that is not a plain
    # badge must never reach the template.
    it 'rejects a token that would escape the icon path' do
      result = apply_route_overrides(data, add: '../../etc/passwd')
      expect(routes(result)).to be_empty
    end

    it 'rejects a token with punctuation' do
      result = apply_route_overrides(data, add: '47"/><script>')
      expect(routes(result)).to be_empty
    end
  end

  describe 'add and remove together' do
    it 'removes first, so a route can be swapped for itself' do
      result = apply_route_overrides(data('А47'), add: 'A47', remove: 'A47')
      expect(routes(result)).to eq(['A47'])
    end

    it 'applies both lists' do
      result = apply_route_overrides(data('А46', 'Т03'), add: 'T02', remove: 'T03')
      expect(routes(result)).to eq(['А46', 'T02'])
    end
  end
end
