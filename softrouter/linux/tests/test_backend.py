"""Synthetic lifecycle evidence only: no nmcli, routes, power or real networking."""
import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('linux_backend', Path(__file__).resolve().parents[1] / 'backend.py')
b = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(b)


def config():
    return {'upstream_interface': 'wlan0', 'upstream_mac': '02:11:22:33:44:55',
            'downstream_interface': 'enx0011', 'downstream_mac': '02:11:22:33:44:66',
            'downstream_address': '192.168.77.1/24'}


def snapshot():
    return {'adapters': [
        {'interface': 'wlan0', 'mac': '02:11:22:33:44:55', 'managed': True, 'physical': True,
         'type': 'wifi', 'state': '100 (connected)', 'active_uuid': 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'},
        {'interface': 'enx0011', 'mac': '02:11:22:33:44:66', 'managed': True, 'physical': True,
         'type': 'ethernet', 'state': '30 (disconnected)', 'active_uuid': '--', 'carrier': True}],
        'addresses': [{'ifname': 'wlan0', 'addr_info': [{'family': 'inet', 'local': '10.20.30.10', 'prefixlen': 24}]}],
        'routes': [{'dst': 'default', 'dev': 'wlan0'}, {'dst': '10.20.30.0/24', 'dev': 'wlan0'}],
        'rules': [{'priority': 0, 'table': 'local'}, {'priority': 32766, 'table': 'main'}, {'priority': 32767, 'table': 'default'}],
        'profiles': [], 'forwarding': '0'}


class MemoryStore:
    def __init__(self):
        self.value = None
        self.marker = None
    def read(self):
        return copy.deepcopy(self.value)
    def write(self, value):
        self.value = copy.deepcopy(value)
    def clear(self):
        self.value = None
    def maintenance(self):
        return copy.deepcopy(self.marker)
    def write_maintenance(self, marker):
        self.marker = copy.deepcopy(marker)
    def clear_maintenance(self):
        self.marker = None


class FakeSystem:
    def __init__(self):
        self.data = snapshot()
        self.profiles = {}
        self.active = set()
        self.calls = []
        self.fail_up = False
        self.edit_up = False
        self.fail_delete = False
        self.fail_add = False
    def inspect(self):
        return copy.deepcopy(self.data)
    def profile_ids(self):
        return list(self.profiles)
    def active_ids(self):
        return set(self.active)
    def carrier(self, interface):
        return next(d['carrier'] for d in self.data['adapters'] if d['interface'] == interface)
    def profile(self, identifier):
        return copy.deepcopy(self.profiles[identifier])
    def add(self, cfg, identifier):
        self.calls.append('add')
        if self.fail_add:
            raise b.Refusal('synthetic add failure')
        self.profiles[identifier] = {'connection.uuid': identifier, 'connection.id': b.PROFILE_NAME,
            'connection.type': '802-3-ethernet', 'connection.interface-name': cfg['downstream_interface'],
            'connection.autoconnect': 'no', '802-3-ethernet.mac-address': cfg['downstream_mac'],
            'ipv4.method': 'shared', 'ipv4.addresses': cfg['downstream_address'],
            'ipv4.never-default': 'yes', 'ipv6.method': 'disabled'}
    def autoconnect(self, identifier, value):
        self.calls.append('autoconnect ' + value)
        self.profiles[identifier]['connection.autoconnect'] = value
    def up(self, identifier):
        self.calls.append('up')
        if self.fail_up:
            raise b.Refusal('synthetic activation failure')
        self.active.add(identifier)
        if self.edit_up:
            self.profiles[identifier]['ipv4.dns'] = '192.0.2.99'
    def down(self, identifier):
        self.calls.append('down')
        self.active.remove(identifier)
    def delete(self, identifier):
        self.calls.append('delete')
        if self.fail_delete:
            raise b.Refusal('synthetic deletion failure')
        del self.profiles[identifier]


class ConfigurationTests(unittest.TestCase):
    def test_valid(self):
        self.assertEqual(b.validate_config(config()), config())
    def test_reject_unknown_field(self):
        cfg = config(); cfg['execute'] = 'ignored shell command'
        self.assertRaises(b.Refusal, b.validate_config, cfg)
    def test_reject_shell_interface(self):
        cfg = config(); cfg['downstream_interface'] = 'x;echo unsafe'
        self.assertRaises(b.Refusal, b.validate_config, cfg)
    def test_reject_same_interface_or_mac(self):
        for key in ('interface', 'mac'):
            cfg = config(); cfg['downstream_' + key] = cfg['upstream_' + key]
            self.assertRaises(b.Refusal, b.validate_config, cfg)
    def test_reject_nonprivate_or_nonhost_or_wrong_prefix(self):
        for address in ('198.51.100.1/24', '192.168.77.0/24', '192.168.77.255/24', '10.10.0.1/16', '::1/24'):
            cfg = config(); cfg['downstream_address'] = address
            self.assertRaises(b.Refusal, b.validate_config, cfg)
    def test_duplicate_json_key(self):
        self.assertRaises(b.Refusal, b.decode, '{"name":1,"name":2}')


class CommandFormatTests(unittest.TestCase):
    def test_all_persistent_groups_without_ethernet_or_secret_request(self):
        identifier = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        system = object.__new__(b.System)
        calls = []
        def nm(*args):
            calls.append(args)
            return ('connection.uuid:' + identifier + '\nconnection.type:802-11-wireless\nconnection.timestamp:123\n'
                    'ipv4.method:auto\nproxy.method:none\nethtool.feature-gro:off\n')
        system.nm = nm
        profile = system.profile(identifier)
        self.assertNotIn('connection.timestamp', profile)
        self.assertEqual(calls[-1][calls[-1].index('--fields') + 1], 'profile')
        self.assertIn('multiline', calls[-1])
        self.assertNotIn('--show-secrets', calls[-1])
        self.assertEqual(profile['proxy.method'], 'none')
        self.assertEqual(profile['ethtool.feature-gro'], 'off')


class PreflightTests(unittest.TestCase):
    def test_valid_idle_adapter(self):
        self.assertEqual(b.preflight(config(), snapshot())['downstream'], 'enx0011')
    def test_wrong_default(self):
        state = snapshot(); state['routes'][0]['dev'] = 'enx0011'
        self.assertRaises(b.Refusal, b.preflight, config(), state)
    def test_missing_or_multiple_default(self):
        for routes in ([], [{'dst': 'default', 'dev': 'wlan0'}] * 2):
            state = snapshot(); state['routes'] = routes
            self.assertRaises(b.Refusal, b.preflight, config(), state)
    def test_mac_physical_and_management_identity(self):
        for key, value in [('mac', '02:00:00:00:00:01'), ('physical', False), ('managed', False)]:
            state = snapshot(); state['adapters'][1][key] = value
            self.assertRaises(b.Refusal, b.preflight, config(), state)
    def test_active_downstream(self):
        state = snapshot(); state['adapters'][1]['state'] = '100 (connected)'
        self.assertRaises(b.Refusal, b.preflight, config(), state)
    def test_unplugged_managed_ethernet_allowed(self):
        state = snapshot(); state['adapters'][1].update(state='20 (unavailable)', carrier=False)
        self.assertEqual(b.preflight(config(), state)['downstream'], 'enx0011')
    def test_unknown_carrier_refused(self):
        state = snapshot(); state['adapters'][1]['carrier'] = None
        self.assertRaises(b.Refusal, b.preflight, config(), state)
    def test_existing_address_including_ipv6(self):
        state = snapshot(); state['addresses'].append({'ifname': 'enx0011', 'addr_info': [{'family': 'inet6', 'local': 'fe80::1', 'prefixlen': 64}]})
        self.assertRaises(b.Refusal, b.preflight, config(), state)
    def test_subnet_overlap(self):
        state = snapshot(); state['routes'].append({'dst': '192.168.0.0/16', 'dev': 'wlan0'})
        self.assertRaises(b.Refusal, b.preflight, config(), state)
    def test_existing_gateway(self):
        state = snapshot(); state['forwarding'] = '1'
        self.assertRaises(b.Refusal, b.preflight, config(), state)
    def test_existing_shared_profile(self):
        state = snapshot(); state['profiles'] = [{'ipv4.method': 'shared'}]
        self.assertRaises(b.Refusal, b.preflight, config(), state)
    def test_custom_routing_rule(self):
        state = snapshot(); state['rules'].insert(1, {'priority': 100, 'table': '100'})
        self.assertRaises(b.Refusal, b.preflight, config(), state)
    def test_generic_autoconnect_profile_conflict(self):
        state = snapshot(); state['profiles'] = [{'connection.type': '802-3-ethernet', 'connection.autoconnect': 'yes', 'ipv4.method': 'auto'}]
        self.assertRaises(b.Refusal, b.preflight, config(), state)
    def test_preserve_idle_dhcp_profile(self):
        state = snapshot(); state['profiles'] = [{'connection.type': '802-3-ethernet', 'connection.autoconnect': 'no', 'ipv4.method': 'auto'}]
        self.assertEqual(b.preflight(config(), state)['downstream'], 'enx0011')
    def test_inspect_mismatch_is_read_only(self):
        system = FakeSystem(); system.data['routes'][0]['dev'] = 'other0'
        result = b.inspect_result(system, config())
        self.assertFalse(result['selected_upstream_matches_default'])
        self.assertFalse(result['downstream_verified'])
        self.assertEqual(system.calls, [])


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.system = FakeSystem(); self.store = MemoryStore()
        self.manager = b.Manager(self.system, self.store)
    def test_enable_disable_only_owned_uuid(self):
        result = self.manager.enable(config()); identifier = result['uuid']
        self.system.profiles['bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'] = {'unrelated': 'keep'}
        self.assertIn(identifier, self.system.active)
        self.assertFalse(result['downstream_verified'])
        self.assertEqual(self.store.value['phase'], 'active')
        self.manager.disable()
        self.assertIsNone(self.store.value)
        self.assertEqual(list(self.system.profiles), ['bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'])
    def test_existing_journal_refuses_enable(self):
        self.store.value = {'unknown': 'state'}
        self.assertRaises(b.Refusal, self.manager.enable, config())
        self.assertEqual(self.system.calls, [])
    def test_unplugged_profile_waits_without_rollback(self):
        self.system.data['adapters'][1].update(state='20 (unavailable)', carrier=False)
        result = self.manager.enable(config())
        self.assertEqual(result['status'], 'configured')
        self.assertEqual(self.store.value['phase'], 'configured')
        self.assertFalse(result['downstream_verified'])
        self.assertNotIn('up', self.system.calls)
        self.assertNotIn('delete', self.system.calls)
        self.assertEqual(self.system.profiles[result['uuid']]['connection.autoconnect'], 'yes')
        self.manager.disable()
        self.assertEqual(self.system.profiles, {})
        self.assertNotIn('down', self.system.calls)
    def test_activation_failure_rolls_back_owned_profile(self):
        self.system.fail_up = True
        self.assertRaises(b.Refusal, self.manager.enable, config())
        self.assertEqual(self.system.profiles, {})
        self.assertIsNone(self.store.value)
    def test_add_failure_absent_profile_clears_journal(self):
        self.system.fail_add = True
        self.assertRaises(b.Refusal, self.manager.enable, config())
        self.assertIsNone(self.store.value)
    def test_external_edit_keeps_profile_and_journal(self):
        result = self.manager.enable(config())
        self.system.profiles[result['uuid']]['ipv4.dns'] = '192.0.2.2'
        before = list(self.system.calls)
        self.assertRaises(b.Refusal, self.manager.disable)
        self.assertEqual(self.system.calls, before)
        self.assertIsNotNone(self.store.value)
    def test_added_persistent_group_prevents_all_disable_writes(self):
        for key in ('802-1x.identity', 'ethtool.feature-gro', 'tc.qdiscs', 'proxy.method'):
            with self.subTest(key=key):
                self.setUp()
                result = self.manager.enable(config())
                self.system.profiles[result['uuid']][key] = 'externally-edited'
                before = list(self.system.calls)
                self.assertRaises(b.Refusal, self.manager.disable)
                self.assertEqual(self.system.calls, before)
                self.assertIsNotNone(self.store.value)
    def test_edit_during_activation_preserves_recovery(self):
        self.system.edit_up = True
        self.assertRaises(b.Refusal, self.manager.enable, config())
        self.assertIsNotNone(self.store.value)
        self.assertNotIn('delete', self.system.calls)
    def test_delete_failure_preserves_journal(self):
        self.manager.enable(config()); self.system.fail_delete = True
        self.assertRaises(b.Refusal, self.manager.disable)
        self.assertIsNotNone(self.store.value)
    def test_absent_profile_safe_clear(self):
        self.manager.enable(config()); self.system.profiles.clear()
        self.assertEqual(self.manager.disable()['status'], 'disabled')
        self.assertIsNone(self.store.value)
    def test_symlink_journal_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory); (base / 'target').write_text('{}')
            (base / 'ownership.json').symlink_to(base / 'target')
            self.assertRaises(b.Refusal, b.Store(base).read)


class PackageMaintenanceTests(unittest.TestCase):
    def setUp(self):
        self.system = FakeSystem(); self.store = MemoryStore()
        self.manager = b.Manager(self.system, self.store)
    def test_begin_blocks_already_open_gui_enable_without_network_calls(self):
        self.assertEqual(b.package_begin(self.store)['status'], 'maintenance')
        self.assertRaises(b.Refusal, self.manager.enable, config())
        self.assertEqual(self.system.calls, [])
        self.assertIsNotNone(self.store.marker)
    def test_enable_first_prevents_package_begin(self):
        self.manager.enable(config())
        self.assertRaises(b.Refusal, b.package_begin, self.store)
        self.assertIsNone(self.store.marker)
    def test_interrupted_begin_is_idempotent_and_retains_marker(self):
        b.package_begin(self.store); original = self.store.maintenance()
        b.package_begin(self.store)
        self.assertEqual(self.store.marker, original)
        self.assertRaises(b.Refusal, self.manager.enable, config())
    def test_end_unblocks_only_after_no_ownership(self):
        b.package_begin(self.store)
        self.assertEqual(b.package_end(self.store)['status'], 'app_ready')
        self.assertIsNone(self.store.marker)
        self.assertEqual(self.system.calls, [])
        self.assertEqual(self.manager.enable(config())['status'], 'active')
    def test_end_retains_marker_when_ownership_is_present(self):
        b.package_begin(self.store)
        self.store.value = {'recovery': 'unknown'}
        self.assertRaises(b.Refusal, b.package_end, self.store)
        self.assertIsNotNone(self.store.marker)
    def test_fresh_install_end_is_nonmutating(self):
        self.assertEqual(b.package_end(self.store)['status'], 'app_ready')
        self.assertEqual(self.system.calls, [])
    def test_unknown_marker_is_never_cleared(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory); marker = base / 'maintenance.json'
            marker.write_text('{"schema":1,"kind":"someone_else","token":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}')
            marker.chmod(0o600)
            # Simulate root ownership only; real permission/type/format checks remain.
            with patch.object(b, 'checked_root_path', side_effect=lambda path: path.lstat()):
                self.assertRaises(b.Refusal, b.package_end, b.Store(base))
            self.assertTrue(marker.exists())
    def test_insecure_marker_is_never_cleared(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory); marker = base / 'maintenance.json'
            marker.write_text('{"schema":1,"kind":"softrouter_package_maintenance","token":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}')
            marker.chmod(0o644)
            with patch.object(b, 'checked_root_path', side_effect=lambda path: path.lstat()):
                self.assertRaises(b.Refusal, b.package_end, b.Store(base))
            self.assertTrue(marker.exists())
    def test_symlinked_marker_is_never_cleared(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory); target = base / 'target'; target.write_text('{}')
            marker = base / 'maintenance.json'; marker.symlink_to(target)
            self.assertRaises(b.Refusal, b.package_end, b.Store(base))
            self.assertTrue(marker.is_symlink())
            self.assertEqual(target.read_text(), '{}')


if __name__ == '__main__':
    unittest.main()
