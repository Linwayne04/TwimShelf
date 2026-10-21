import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

@unittest.skipUnless(shutil.which('xcodegen') and shutil.which('ruby'), 'requires XcodeGen and Ruby')
class ConfigureTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name)
        for name in ('app','scripts'):
            shutil.copytree(ROOT/name,self.root/name,ignore=shutil.ignore_patterns('__pycache__'))
        shutil.copyfile(ROOT/'project.yml',self.root/'project.yml')
        self.config=json.loads((ROOT/'build-config.example.json').read_text())
        self.config['bundle_id_prefix']='org.example.twimshelf'
    def generate(self, ok=True):
        (self.root/'build-config.json').write_text(json.dumps(self.config))
        r=subprocess.run([sys.executable,str(self.root/'scripts/configure.py')],capture_output=True,text=True)
        self.assertEqual(r.returncode==0,ok,r.stdout+r.stderr)
        if ok:return json.loads((self.root/'project.generated.yml').read_text())
    def test_off_on_off_updates_targets_entitlements_and_inbox(self):
        for enabled in (False,True,False):
            self.config.update(enable_share_extension=enabled,development_team='ABCDE12345',ios_app_group='group.org.example.twimshelf',macos_app_group='ABCDE12345.org.example.twimshelf')
            p=self.generate()
            self.assertEqual(any(n.endswith('Share') for n in p['targets']),enabled)
            for name,target in p['targets'].items():
                if 'info' not in target:continue
                base=target['settings']['base']
                ent=plistlib.loads((self.root/base['CODE_SIGN_ENTITLEMENTS']).read_bytes())
                group=target['info']['properties']['TwimShelfAppGroup']
                self.assertEqual(bool(group),enabled)
                self.assertEqual('com.apple.security.application-groups' in ent,enabled)
                self.assertEqual(base['PRODUCT_BUNDLE_IDENTIFIER'].startswith('org.example.twimshelf.'),True)
                if not enabled:
                    self.assertFalse(any(d.get('target','').endswith('Share') for d in target.get('dependencies',[])))
    def test_blank_identifier_rejected(self):
        self.config['bundle_id_prefix']='';self.generate(False)
    def test_string_boolean_rejected(self):
        self.config['enable_share_extension']='false';self.generate(False)
    def test_extension_without_team_rejected(self):
        self.config['enable_share_extension']=True;self.generate(False)
if __name__=='__main__':unittest.main()
