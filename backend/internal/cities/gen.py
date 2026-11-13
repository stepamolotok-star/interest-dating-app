# Собирает cities.json из city.csv (github.com/hflabs/city, CC BY-SA 4.0):
#   curl -LO https://raw.githubusercontent.com/hflabs/city/master/city.csv
#   python3 gen.py city.csv cities.json
import csv, json, re, sys
tz = {'UTC+2':'Europe/Kaliningrad','UTC+3':'Europe/Moscow','UTC+4':'Europe/Samara','UTC+5':'Asia/Yekaterinburg',
      'UTC+6':'Asia/Omsk','UTC+7':'Asia/Novosibirsk','UTC+8':'Asia/Irkutsk','UTC+9':'Asia/Chita',
      'UTC+10':'Asia/Vladivostok','UTC+11':'Asia/Magadan','UTC+12':'Asia/Kamchatka'}
def region(t, r):
    r = r.strip()
    if t == 'обл': return f'{r} область'
    if t == 'край': return f'{r} край'
    if t == 'Аобл': return f'{r} автономная область'
    if t == 'АО':
        r = r.replace('Автономный округ', 'автономный округ').replace(' - ', ' — ')
        return r if 'округ' in r else f'{r} автономный округ'
    if t == 'Чувашия': return 'Чувашская Республика'
    if t == 'г': return ''
    if t == 'Респ':
        r = r.replace(' /Якутия/', ' (Якутия)').replace(' - ', ' — ')
        return f'{r} Республика' if re.search(r'(ская|цкая)$', r) else f'Республика {r}'
    raise SystemExit('unknown region type ' + t)
out = []
for x in csv.DictReader(open(sys.argv[1])):
    name = x['city'] or x['settlement'] or (x['area'] if x['area_type'] == 'г' else '') or x['region']
    out.append({'id': x['fias_id'], 'name': name, 'region': region(x['region_type'], x['region']),
                'lat': round(float(x['geo_lat']), 4), 'lon': round(float(x['geo_lon']), 4),
                'pop': int(float(x['population'] or 0)), 'tz': tz[x['timezone']]})
out.sort(key=lambda c: -c['pop'])
json.dump({'source': 'github.com/hflabs/city (CC BY-SA 4.0), данные DaData.ru и Википедии', 'cities': out},
          open(sys.argv[2], 'w'), ensure_ascii=False, separators=(',', ':'))
print(len(out), sorted({c['region'] for c in out if 'Респ' in c['region'] or 'округ' in c['region'] or c['region']==''}))
