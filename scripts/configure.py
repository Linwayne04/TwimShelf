#!/usr/bin/env python3
"""Generate a disposable Xcode project from public templates and private builder settings."""
import json, re, shutil, subprocess, plistlib
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
def main():
    path = ROOT / 'build-config.json'
    if not path.exists():
        raise SystemExit('Copy build-config.example.json to build-config.json and fill bundle_id_prefix first.')
    c = json.loads(path.read_text())
    prefix = c.get('bundle_id_prefix', '')
    if not re.fullmatch(r'[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+)+', prefix):
        raise SystemExit('bundle_id_prefix must be your reverse-DNS identifier, e.g. com.example.twimshelf.')
    enabled = c.get('enable_share_extension')
    if type(enabled) is not bool:
        raise SystemExit('enable_share_extension must be a JSON boolean, not a string.')
    team = c.get('development_team', '')
    if enabled:
        if not re.fullmatch(r'[A-Z0-9]{10}', team):
            raise SystemExit('Share extension requires your ten-character development_team.')
        if not c.get('ios_app_group', '').startswith('group.') or not c.get('macos_app_group', '').startswith(team + '.'):
            raise SystemExit('Supply registered ios_app_group (group.*) and macos_app_group (TEAMID.*).')
    # System Ruby/Psych reads YAML without requiring a Python package installation.
    raw = subprocess.check_output(['ruby', '-ryaml', '-rjson', '-e',
        'puts JSON.generate(YAML.load_file(ARGV[0]))', str(ROOT / 'project.yml')])
    spec = json.loads(raw)
    spec['name'] = 'TwimShelf'
    spec['options']['bundleIdPrefix'] = ''
    spec['settings']['base']['ASSETCATALOG_COMPILER_APPICON_NAME'] = c.get('app_icon_name', '')
    generated = ROOT / '.generated'
    generated.mkdir(exist_ok=True)
    suffixes = {'TwitterLibrary-iOS': '.ios', 'TwitterLibrary-macOS': '.mac',
        'TwitterLibrary-iOSShare': '.ios.share', 'TwitterLibrary-macOSShare': '.mac.share',
        'TwitterLibrary-iOSUITests': '.uitests'}
    if not enabled:
        for name in list(spec['targets']):
            if name.endswith('Share'): del spec['targets'][name]
    for name, target in spec['targets'].items():
        settings = target.setdefault('settings', {})
        base = settings.setdefault('base', {})
        base['PRODUCT_BUNDLE_IDENTIFIER'] = prefix + suffixes[name]
        base['DEVELOPMENT_TEAM'] = team
        base['CODE_SIGN_STYLE'] = 'Automatic' if team else 'Manual'
        base['CODE_SIGN_IDENTITY'] = 'Apple Development' if team else '-'
        for config, values in settings.get('configs', {}).items():
            if 'PRODUCT_BUNDLE_IDENTIFIER' in values:
                values['PRODUCT_BUNDLE_IDENTIFIER'] = prefix + ('.mac.debug.share' if name.endswith('Share') else '.mac.debug')
        if not enabled:
            target['dependencies'] = [d for d in target.get('dependencies', []) if not d.get('target', '').endswith('Share')]
        # Source Info.plist / entitlement templates must not become copied resources.
        target['sources'] = [dict(path=v, excludes=['Info.plist', '*.entitlements'])
            if isinstance(v, str) and (ROOT / v).is_dir() else v
            for v in target.get('sources', [])]
        if 'info' in target:
            target['info']['path'] = '.generated/' + name + '-Info.plist'
            group = c.get('ios_app_group' if target['platform'] == 'iOS' else 'macos_app_group', '') if enabled else ''
            target['info']['properties']['TwimShelfAppGroup'] = group
            ent = {}
            if enabled: ent['com.apple.security.application-groups'] = [group]
            if name == 'TwitterLibrary-macOSShare':
                ent.update({'com.apple.security.app-sandbox': True, 'com.apple.security.files.user-selected.read-only': True})
            entpath = '.generated/' + name + '.entitlements'
            (ROOT / entpath).write_bytes(plistlib.dumps(ent))
            base['CODE_SIGN_ENTITLEMENTS'] = entpath
    (ROOT / 'project.generated.yml').write_text(json.dumps(spec, indent=2) + '\n')
    subprocess.run(['xcodegen', 'generate', '--spec', 'project.generated.yml'], cwd=ROOT, check=True)
    lock = ROOT / 'dependencies/Package.resolved'
    if lock.exists():
        dest = ROOT / 'TwimShelf.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(lock, dest)
    print('Generated TwimShelf.xcodeproj; share extension:', enabled)
if __name__ == '__main__': main()
