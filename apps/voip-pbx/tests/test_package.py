import json
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[1]


class PackageTests(unittest.TestCase):
    def test_manifest_is_generic_private_and_unprivileged(self):
        manifest = json.loads((ROOT / 'app.json').read_text())
        self.assertEqual(manifest['id'], 'voip-pbx')
        self.assertEqual(manifest['name'], 'MikoPBX')
        self.assertFalse(manifest['network']['public'])
        self.assertFalse(manifest['capabilities']['privileged'])
        self.assertNotIn('titus', json.dumps(manifest).lower())

    def test_official_image_is_version_pinned(self):
        compose = (ROOT / 'docker-compose.yml').read_text()
        self.assertIn('ghcr.io/mikopbx/mikopbx@sha256:f6c023fde04372a13bec82ba563cae1d5738caf5c134bf78615b68d4b012d943', compose)
        self.assertNotIn(':latest', compose)
        self.assertNotIn('build:', compose)

    def test_network_is_private_and_ports_are_explicit(self):
        compose = (ROOT / 'docker-compose.yml').read_text()
        self.assertIn('voip-pbx-private:', compose)
        self.assertIn('internal: true', compose)
        self.assertIn('20000-20800:20000-20800/udp', compose)
        self.assertIn('5061:5061/tcp', compose)
        self.assertNotIn('network_mode: host', compose)

    def test_only_required_capability_is_added(self):
        compose = (ROOT / 'docker-compose.yml').read_text()
        self.assertIn('- NET_ADMIN', compose)
        for forbidden in ('privileged: true', '/var/run/docker.sock', '- SYS_ADMIN'):
            self.assertNotIn(forbidden, compose)

    def test_initial_web_credentials_are_injected_from_root_only_secret_file(self):
        compose = (ROOT / 'docker-compose.yml').read_text()
        setup = (ROOT / 'setup.sh').read_text()
        self.assertIn('WEB_ADMIN_LOGIN: admin', compose)
        self.assertIn('WEB_ADMIN_PASSWORD=', setup)
        self.assertIn('chmod 600', setup)
        self.assertIn('env_file:', compose)

    def test_titus_is_kept_out_of_generic_package(self):
        package = ''.join(
            (ROOT / name).read_text(errors='ignore')
            for name in ('app.json', 'params.json', 'docker-compose.yml', 'setup.sh')
        )
        self.assertNotIn('3630', package)
        self.assertNotIn('Titus', package)


if __name__ == '__main__':
    unittest.main()
