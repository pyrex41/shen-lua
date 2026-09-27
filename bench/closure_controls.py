"""Fresh-process alternating-order controls; run from repository root."""
import csv, io, json, subprocess, statistics
rows = []
for round in range(4):
    for mode in (['off', 'on'] if round % 2 == 0 else ['on', 'off']):
        p = subprocess.run(['luajit', 'bench/closures.lua', '200000', mode],
                           text=True, capture_output=True, check=True, timeout=60)
        for row in csv.DictReader(io.StringIO('\n'.join(p.stdout.splitlines()[1:]))):
            row['round'] = round
            rows.append(row)
with open('bench/results/closure-controls.json', 'w') as f:
    json.dump(rows, f, indent=2)
for case in ['immediate', 'local', 'escaping', 'deferred']:
    values = {m: [float(r['median_seconds']) for r in rows if r['case']==case and r['mode']==m] for m in ['off','on']}
    med = {m: statistics.median(v) for m,v in values.items()}
    print(case, values, 'median on/off=', med['on']/med['off'])
