#!/usr/bin/env python3
import re, json
from subprocess import Popen, PIPE

p = Popen([
    'plutil',
    '-convert', 'json',
    '/System/Library/CoreServices/CoreTypes.bundle/Contents/Library/MobileDevices.bundle/Contents/Info.plist',
    '-o', '-'
], stdout=PIPE)

data = json.load(p.stdout)
mapping = {}

for item in data['UTExportedTypeDeclarations']:
    if 'UTTypeTagSpecification' not in item: continue
    for code in item['UTTypeTagSpecification']['com.apple.device-model-code']:
        if re.match(r'^[a-zA-Z]+\d+,\d+$', code):
            name = item['UTTypeDescription']
            name = re.sub(r'Model A?\d+(, A?\d+)*', '', name)
            name = re.sub(r' *?\)', ')', name)
            name = re.sub(r' \(\)', '', name)
            mapping[code] = name

print('let appleDeviceNames = [')
for code, name in mapping.items():
    print(f'    "{code}": "{name}",')
print(']')
