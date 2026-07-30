#!/usr/bin/env python3
"""One-shot script: strip hermes-webui container + svc from 06-hermes.yaml."""
import ruamel.yaml, pathlib
p = pathlib.Path('deploy/k3s/manifests/06-hermes.yaml')
y = ruamel.yaml.YAML()
y.preserve_quotes = True
y.width = 4096
docs = list(y.load_all(p))
out = []
for d in docs:
    if not d:
        continue
    kind = d.get('kind')
    name = d.get('metadata', {}).get('name', '')
    # Drop the WebUI-only Service
    if kind == 'Service' and name == 'hermes-webui-svc':
        print(f'  removed Service/{name}')
        continue
    # Trim Deployment/hermes
    if kind == 'Deployment' and name == 'hermes':
        containers = d['spec']['template']['spec']['containers']
        before = len(containers)
        d['spec']['template']['spec']['containers'] = [
            c for c in containers if c['name'] != 'hermes-webui'
        ]
        after = len(d['spec']['template']['spec']['containers'])
        print(f'  Deployment/hermes containers: {before} -> {after}')
        # Drop volumes only used by webui (oauth-patch mount was webui-only)
        vols = d['spec']['template']['spec'].get('volumes', [])
        d['spec']['template']['spec']['volumes'] = [
            v for v in vols if v.get('name') != 'oauth-patch'
        ]
        vol_names = [v['name'] for v in d['spec']['template']['spec']['volumes']]
        print(f'  volumes now: {vol_names}')
    out.append(d)
with p.open('w') as f:
    y.dump_all(out, f)
print('done - wrote', p)
