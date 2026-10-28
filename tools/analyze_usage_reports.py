"""Merge only voluntary, fixed-schema counter reports. No network or tracking IDs."""
import argparse
import collections
import csv
import datetime
import hashlib
import json
import re
from pathlib import Path

EVENTS = {'appOpened','savedRoutesOpened','chatsOpened','communityOpened','trainingOpened',
'achievementsOpened','heatmapOpened','offlineMapsOpened','groupOpened','garageOpened',
'workoutStarted','workoutPaused','workoutResumed','workoutSaved','workoutSaveFailed',
'workoutDiscarded','routeBuilt','routeBuildFailed','gpsStreamFailed','gpsRecoveryStarted','gpsRecovered'}

def validate(data):
    if set(data) != {'schema','automatic_upload','retention_days','counters'} or data['schema'] != 'pulsepath-usage-counters-v1' or data['automatic_upload'] is not False or data['retention_days'] != 30:
        raise ValueError('Unexpected report schema')
    if not isinstance(data['counters'],list) or len(data['counters'])>10000:
        raise ValueError('Invalid counter list')
    for row in data['counters']:
        if set(row) != {'day','version','event','count'} or row['event'] not in EVENTS or type(row['count']) is not int or not 0<row['count']<=1000000:
            raise ValueError('Invalid counter')
        datetime.date.fromisoformat(row['day'])
        if not isinstance(row['version'],str) or not re.fullmatch(r'(?:unknown|[0-9][0-9A-Za-z.+_-]{0,49})',row['version']):
            raise ValueError('Invalid version')
    return data['counters']

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('reports',nargs='+',type=Path)
    parser.add_argument('--output',type=Path,default=Path('analysis-output/usage.csv'))
    args=parser.parse_args()
    totals=collections.Counter(); reports=collections.Counter(); seen=set(); accepted=0
    for path in args.reports:
        raw=path.read_bytes()
        if len(raw)>250000: raise ValueError('Report is too large')
        digest=hashlib.sha256(raw).digest()
        if digest in seen: continue
        seen.add(digest)
        rows=validate(json.loads(raw.decode('utf-8-sig'))); accepted+=1
        covered=set()
        for row in rows:
            key=(row['version'],row['event'])
            totals[key]+=row['count']; covered.add(key)
        reports.update(covered)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    with args.output.open('w',encoding='utf-8-sig',newline='') as file:
        writer=csv.writer(file);writer.writerow(['version','event','events','reports_with_event'])
        for key in sorted(totals): writer.writerow([*key,totals[key],reports[key]])
    print('Reports accepted: %d. Counts are events/reports, not unique users. Output: %s' % (accepted,args.output))
    print('Repeated cumulative reports from one person can overlap; request one report per test period.')
if __name__=='__main__': main()
