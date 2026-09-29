#!/usr/bin/python3
"""Experimental Linux adapter. NetworkManager owns routing, DHCP and DNS."""
import argparse
import contextlib
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import uuid

STATE_DIR = Path('/var/lib/softrouter')
INSTALL_DIR = Path('/opt/softrouter')
ENV = {'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LC_ALL': 'C'}
PROFILE_NAME = 'SoftRouter community test'
KEYS = {'upstream_interface', 'upstream_mac', 'downstream_interface',
        'downstream_mac', 'downstream_address'}
PRIVATE = [ipaddress.ip_network(n) for n in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16')]


class Refusal(RuntimeError):
    pass


def object_unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise Refusal('Duplicate JSON key: ' + key)
        result[key] = value
    return result


def decode(text):
    try:
        return json.loads(text, object_pairs_hook=object_unique)
    except (ValueError, TypeError) as exc:
        raise Refusal('Invalid JSON data.') from exc


def validate_config(data):
    if not isinstance(data, dict) or set(data) != KEYS:
        raise Refusal('Configuration must contain exactly: ' + ', '.join(sorted(KEYS)))
    config = dict(data)
    for role in ('upstream', 'downstream'):
        name = config[role + '_interface']
        mac = config[role + '_mac']
        if not isinstance(name, str) or not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_.-]{0,14}', name):
            raise Refusal('Invalid interface name.')
        if not isinstance(mac, str) or not re.fullmatch(r'(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}', mac):
            raise Refusal('Invalid MAC address.')
        if int(mac[:2], 16) & 1 or mac.lower() == '00:00:00:00:00:00':
            raise Refusal('Expected a unicast hardware MAC address.')
        config[role + '_mac'] = mac.upper()
    if config['upstream_interface'] == config['downstream_interface'] or config['upstream_mac'] == config['downstream_mac']:
        raise Refusal('Upstream and downstream must be different physical adapters.')
    try:
        address = ipaddress.IPv4Interface(config['downstream_address'])
    except (ValueError, TypeError) as exc:
        raise Refusal('Expected a private IPv4 host address with /24 prefix.') from exc
    if address.network.prefixlen != 24 or not any(address.ip in n for n in PRIVATE) or address.ip in (address.network.network_address, address.network.broadcast_address):
        raise Refusal('Downstream must be a host address in an RFC1918 /24 subnet.')
    config['downstream_address'] = str(address)
    return config


def executable(candidates):
    for candidate in candidates:
        if Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return candidate
    raise Refusal('Required system program is missing: ' + candidates[0])


def run(command):
    try:
        result = subprocess.run(command, capture_output=True, text=True, env=ENV, timeout=25, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Refusal('System command unavailable or timed out: ' + command[0]) from exc
    if len(result.stdout) + len(result.stderr) > 1048576:
        raise Refusal('System command output exceeded the safety limit.')
    if result.returncode:
        raise Refusal('System command failed: ' + result.stderr.strip()[:800])
    return result.stdout


class System:
    def __init__(self):
        self.nm_path = executable(['/usr/bin/nmcli', '/bin/nmcli'])
        self.ip_path = executable(['/usr/sbin/ip', '/usr/bin/ip', '/sbin/ip', '/bin/ip'])

    def nm(self, *args):
        return run([self.nm_path, '--wait', '20', '--colors', 'no', *args])

    def property(self, field, *target):
        return self.nm('--escape', 'no', '--get-values', field, *target).strip()

    def profile_ids(self):
        ids = self.property('UUID', 'connection', 'show').splitlines()
        if len(ids) > 200 or any(not valid_uuid(x) for x in ids):
            raise Refusal('Connection inventory is invalid or too large.')
        return ids

    def active_ids(self):
        return set(self.property('UUID', 'connection', 'show', '--active').splitlines())

    def profile(self, identifier):
        if not valid_uuid(identifier):
            raise Refusal('Invalid connection UUID.')
        # The documented profile selector includes every persistent settings group,
        # including externally added 802-1x/ethtool/tc/proxy properties. Never use
        # --show-secrets. Runtime GENERAL/IP4/DHCP4/IP6 groups are not requested.
        raw = self.nm('--terse', '--mode', 'multiline', '--escape', 'no', '--fields',
                      'profile', 'connection', 'show', 'uuid', identifier)
        result = {}
        for line in raw.splitlines():
            key, separator, value = line.partition(':')
            if not separator or not re.fullmatch(r'[a-zA-Z0-9_.-]+', key) or key in result:
                raise Refusal('Unexpected connection settings format; ownership cannot be checked.')
            if key != 'connection.timestamp':
                result[key] = value
        if result.get('connection.uuid') != identifier:
            raise Refusal('Connection UUID did not match its queried profile.')
        return result

    def carrier(self, interface):
        value = self.property('WIRED-PROPERTIES.CARRIER', 'device', 'show', interface)
        return True if value == 'on' else False if value == 'off' else None

    def inspect(self):
        devices = []
        names = self.property('DEVICE', 'device', 'status').splitlines()
        if len(names) > 100:
            raise Refusal('Adapter inventory is too large.')
        for name in names:
            if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_.-]{0,14}', name):
                continue
            values = self.nm('--escape', 'no', '--get-values',
                             'GENERAL.TYPE,GENERAL.STATE,GENERAL.HWADDR,GENERAL.NM-MANAGED,GENERAL.CON-UUID',
                             'device', 'show', name).splitlines()
            if len(values) != 5:
                raise Refusal('Unexpected adapter inventory format.')
            devices.append(dict(interface=name, type=values[0], state=values[1], mac=values[2].upper(),
                                managed=values[3] == 'yes', active_uuid=values[4],
                                carrier=self.carrier(name) if values[0] == 'ethernet' else None,
                                physical=(Path('/sys/class/net') / name / 'device').exists()))
        addresses = decode(run([self.ip_path, '-json', 'address', 'show']))
        routes = decode(run([self.ip_path, '-json', '-4', 'route', 'show', 'table', 'all']))
        rules = decode(run([self.ip_path, '-json', '-4', 'rule', 'show']))
        profiles = [self.profile(identifier) for identifier in self.profile_ids()]
        return dict(adapters=devices, addresses=addresses, routes=routes, rules=rules,
                    profiles=profiles, forwarding=Path('/proc/sys/net/ipv4/ip_forward').read_text().strip())

    def add(self, config, identifier):
        self.nm('connection', 'add', 'type', 'ethernet', 'ifname', config['downstream_interface'],
                'con-name', PROFILE_NAME, 'connection.uuid', identifier,
                '802-3-ethernet.mac-address', config['downstream_mac'], 'connection.autoconnect', 'no',
                'ipv4.method', 'shared', 'ipv4.addresses', config['downstream_address'],
                'ipv4.never-default', 'yes', 'ipv6.method', 'disabled')

    def autoconnect(self, identifier, value):
        self.nm('connection', 'modify', 'uuid', identifier, 'connection.autoconnect', value)

    def up(self, identifier):
        self.nm('connection', 'up', 'uuid', identifier)

    def down(self, identifier):
        self.nm('connection', 'down', 'uuid', identifier)

    def delete(self, identifier):
        self.nm('connection', 'delete', 'uuid', identifier)


def valid_uuid(value):
    try:
        return isinstance(value, str) and str(uuid.UUID(value)) == value
    except ValueError:
        return False


def empty(value):
    return value in ('', '--', None)


def preflight(config, snapshot):
    adapters = {d['interface']: d for d in snapshot['adapters']}
    for role in ('upstream', 'downstream'):
        adapter = adapters.get(config[role + '_interface'])
        if not adapter or not adapter['physical'] or not adapter['managed'] or adapter['mac'] != config[role + '_mac']:
            raise Refusal('Interface/MAC must match a physical NetworkManager-managed adapter: ' + role)
        allowed = ('wifi', 'ethernet') if role == 'upstream' else ('ethernet',)
        if adapter['type'] not in allowed:
            raise Refusal('Unsupported adapter type: ' + role)
    down = config['downstream_interface']
    up = config['upstream_interface']
    defaults = [r for r in snapshot['routes'] if r.get('dst') == 'default']
    if len(defaults) != 1 or defaults[0].get('dev') != up:
        raise Refusal('Exactly one IPv4 default route must use the selected upstream; policy routing is unsupported.')
    if not adapters[up]['state'].startswith('100 ') or empty(adapters[up]['active_uuid']):
        raise Refusal('The selected upstream must already be connected.')
    idle = adapters[down]['state'].startswith('30 ')
    waiting_for_cable = adapters[down]['state'].startswith('20 ') and adapters[down].get('carrier') is False
    if (not idle and not waiting_for_cable) or not empty(adapters[down]['active_uuid']):
        raise Refusal('Downstream must be disconnected and idle before enabling sharing.')
    if adapters[down].get('carrier') not in (True, False):
        raise Refusal('Downstream Ethernet carrier state is unknown; no activation assumptions will be made.')
    if snapshot['forwarding'] != '0':
        raise Refusal('IPv4 forwarding is already enabled; an existing gateway or unknown owner may be present.')
    expected_rules = [(0, 'local'), (32766, 'main'), (32767, 'default')]
    if [(r.get('priority'), r.get('table')) for r in snapshot['rules']] != expected_rules:
        raise Refusal('Custom IPv4 routing rules are present or cannot be identified.')
    network = ipaddress.ip_interface(config['downstream_address']).network
    for entry in snapshot['addresses']:
        if entry.get('ifname') == down and entry.get('master'):
            raise Refusal('Downstream belongs to another interface controller; its ownership is unclear.')
        for address in entry.get('addr_info', []):
            if entry.get('ifname') == down:
                raise Refusal('Downstream already has an address; no existing network configuration will be overwritten.')
            if address.get('family') == 'inet':
                existing = ipaddress.ip_network(str(address['local']) + '/' + str(address['prefixlen']), strict=False)
                if network.overlaps(existing):
                    raise Refusal('Requested subnet overlaps an existing interface subnet.')
    for route in snapshot['routes']:
        if route.get('dst') not in ('default', None):
            try:
                existing = ipaddress.ip_network(route['dst'], strict=False)
            except ValueError as exc:
                raise Refusal('Unrecognized IPv4 route.') from exc
            if network.overlaps(existing):
                raise Refusal('Requested subnet overlaps an existing route.')
    for profile in snapshot['profiles']:
        if profile.get('ipv4.method') == 'shared' or profile.get('ipv6.method') == 'shared':
            raise Refusal('An existing shared connection is present; installation alongside a gateway is unsupported.')
        if profile.get('connection.type') != '802-3-ethernet':
            continue
        bound = profile.get('connection.interface-name')
        mac = profile.get('802-3-ethernet.mac-address')
        if not empty(bound) and bound != down:
            continue
        if not empty(mac) and mac.upper() != config['downstream_mac']:
            continue
        if profile.get('connection.autoconnect') != 'no' or profile.get('ipv4.method') != 'auto' or not empty(profile.get('ipv4.addresses')):
            raise Refusal('A matching Ethernet profile may claim downstream; it must be inactive DHCP with autoconnect off.')
    return dict(upstream=up, downstream=down, downstream_address=config['downstream_address'],
                egress='NetworkManager shared NAT follows the current default route; it is not pinned to upstream.')


def checked_root_path(path, directory=False):
    info = path.lstat()
    expected = stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)
    if not expected or info.st_uid != 0 or info.st_mode & 0o022:
        raise Refusal('Expected a root-owned path without group/world write access: ' + str(path))
    return info


class Store:
    def __init__(self, directory=STATE_DIR):
        self.directory = directory
        self.path = directory / 'ownership.json'
        self.maintenance_path = directory / 'maintenance.json'

    def prepare(self):
        checked_root_path(self.directory.parent, directory=True)
        if not self.directory.exists() and not self.directory.is_symlink():
            self.directory.mkdir(mode=0o700)
        info = checked_root_path(self.directory, directory=True)
        if stat.S_IMODE(info.st_mode) != 0o700:
            raise Refusal('Ownership directory must have mode 0700; leave unknown recovery data intact.')

    @contextlib.contextmanager
    def lock(self):
        self.prepare()
        descriptor = os.open(str(self.directory / 'operation.lock'), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1:
                raise Refusal('Ownership lock is not a private root-owned regular file.')
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise Refusal('Another SoftRouter operation is running.') from exc
            yield
        finally:
            os.close(descriptor)

    def read(self):
        if not self.path.exists() and not self.path.is_symlink():
            return None
        info = checked_root_path(self.path)
        if stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1 or info.st_size > 65536:
            raise Refusal('Ownership journal is not a private regular file.')
        descriptor = os.open(str(self.path), os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(descriptor) as source:
            data = decode(source.read(65537))
        if not isinstance(data, dict) or data.get('schema') != 1 or not valid_uuid(data.get('uuid')) or not isinstance(data.get('allowed_profiles'), list):
            raise Refusal('Unknown ownership journal; manual recovery is required.')
        return data

    def maintenance(self):
        path = self.maintenance_path
        if not path.exists() and not path.is_symlink():
            return None
        info = checked_root_path(path)
        if stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1 or info.st_size > 4096:
            raise Refusal('Maintenance marker is not a private root-owned regular file; it was preserved.')
        descriptor = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(descriptor) as source:
            data = decode(source.read(4097))
        if (not isinstance(data, dict) or set(data) != {'schema', 'kind', 'token'}
                or type(data.get('schema')) is not int or data.get('schema') != 1
                or data.get('kind') != 'softrouter_package_maintenance'
                or not valid_uuid(data.get('token'))):
            raise Refusal('Unknown maintenance marker; it was preserved for manual recovery.')
        return data

    def _write(self, path, data):
        descriptor, name = tempfile.mkstemp(prefix='.journal-', dir=str(self.directory))
        try:
            with os.fdopen(descriptor, 'w') as target:
                json.dump(data, target, sort_keys=True)
                target.flush()
                os.fsync(target.fileno())
            os.replace(name, str(path))
            directory_fd = os.open(str(self.directory), os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        finally:
            if os.path.exists(name):
                os.unlink(name)

    def write(self, data):
        self._write(self.path, data)

    def write_maintenance(self, data):
        self._write(self.maintenance_path, data)

    def clear_maintenance(self):
        self.maintenance_path.unlink()

    def clear(self):
        self.path.unlink()


class Manager:
    def __init__(self, system, store):
        self.system = system
        self.store = store

    def owned_profile(self, state):
        actual = self.system.profile(state['uuid'])
        if actual not in state['allowed_profiles']:
            raise Refusal('Owned profile was changed outside SoftRouter; it will not be modified or deleted. Journal retained.')
        return actual

    def set_autoconnect(self, state, value):
        current = self.owned_profile(state)
        expected = dict(current)
        expected['connection.autoconnect'] = value
        state['allowed_profiles'] = [current, expected]
        self.store.write(state)
        self.system.autoconnect(state['uuid'], value)
        actual = self.owned_profile(state)
        if actual != expected:
            raise Refusal('Autoconnect change did not match the planned profile. Journal retained.')
        state['allowed_profiles'] = [actual]
        self.store.write(state)

    def disable(self):
        state = self.store.read()
        if state is None:
            return dict(status='unchanged', detail='No owned profile is recorded.')
        identifier = state['uuid']
        if identifier not in self.system.profile_ids():
            self.store.clear()
            return dict(status='disabled', detail='Recorded profile was already absent; journal cleared.')
        self.set_autoconnect(state, 'no')
        if identifier in self.system.active_ids():
            self.owned_profile(state)
            self.system.down(identifier)
        self.owned_profile(state)
        self.system.delete(identifier)
        if identifier in self.system.profile_ids():
            raise Refusal('Owned profile still exists after deletion; journal retained.')
        self.store.clear()
        return dict(status='disabled', detail='Only the recorded, unchanged UUID was deactivated and removed. '
                    'NetworkManager owns the routing, DHCP and firewall effects; complete system restoration was not measured.')

    def enable(self, config):
        config = validate_config(config)
        if self.store.maintenance() is not None:
            raise Refusal('Application installation, upgrade or removal is in progress or was interrupted. '
                          'Sharing is blocked by the preserved maintenance marker until package-end completes safely.')
        if self.store.read() is not None:
            raise Refusal('An ownership journal already exists. Disable or recover that deployment first.')
        plan = preflight(config, self.system.inspect())
        identifier = str(uuid.uuid4())
        state = dict(schema=1, uuid=identifier, config=config, phase='prepared', allowed_profiles=[])
        self.store.write(state)
        try:
            self.system.add(config, identifier)
            profile = self.system.profile(identifier)
            required = {'connection.uuid': identifier, 'connection.id': PROFILE_NAME,
                        'connection.type': '802-3-ethernet', 'connection.interface-name': config['downstream_interface'],
                        'connection.autoconnect': 'no', '802-3-ethernet.mac-address': config['downstream_mac'],
                        'ipv4.method': 'shared', 'ipv4.addresses': config['downstream_address'],
                        'ipv4.never-default': 'yes', 'ipv6.method': 'disabled'}
            if any(profile.get(key) != value for key, value in required.items()):
                raise Refusal('Created connection does not match the requested settings; journal retained.')
            state.update(phase='created', allowed_profiles=[profile])
            self.store.write(state)
            self.set_autoconnect(state, 'yes')
            if self.system.carrier(config['downstream_interface']) is False:
                self.owned_profile(state)
                state['phase'] = 'configured'
                self.store.write(state)
                return dict(status='configured', uuid=identifier, plan=plan, downstream_verified=False,
                            detail='Profile saved with autoconnect. Ethernet carrier is absent; waiting for a cable. '
                            'NetworkManager will attempt activation when the link appears. Sharing is not yet verified active.')
            self.system.up(identifier)
            self.owned_profile(state)
            if identifier not in self.system.active_ids():
                raise Refusal('NetworkManager did not report the owned profile active.')
            state['phase'] = 'active'
            self.store.write(state)
            return dict(status='active', uuid=identifier, plan=plan, downstream_verified=False,
                        detail='NetworkManager manages this persistent profile. Reboot recovery and real downstream access are unverified.')
        except Exception as original:
            try:
                self.disable()
                recovery = 'Owned profile rollback completed.'
            except Exception as cleanup:
                recovery = 'Recovery incomplete; root ownership journal retained: ' + str(cleanup)
            raise Refusal(str(original) + ' ' + recovery) from original


def inspect_result(system, config=None):
    snapshot = system.inspect()
    active = {adapter['active_uuid'] for adapter in snapshot['adapters'] if not empty(adapter['active_uuid'])}
    result = dict(kind='read_only_snapshot', adapters=snapshot['adapters'],
                  default_routes=[r for r in snapshot['routes'] if r.get('dst') == 'default'],
                  shared_profiles=[{'uuid': p['connection.uuid'], 'interface': p.get('connection.interface-name'),
                                    'name': p.get('connection.id'),
                                    'status': 'active' if p['connection.uuid'] in active else 'configured_inactive'}
                                   for p in snapshot['profiles'] if p.get('ipv4.method') == 'shared'],
                  downstream_verified=False,
                  boundary='Shared NAT follows the current default route. Link and profile state do not prove downstream internet access.')
    if config:
        config = validate_config(config)
        defaults = result['default_routes']
        result['selected_upstream_matches_default'] = len(defaults) == 1 and defaults[0].get('dev') == config['upstream_interface']
        try:
            result['enable_plan'] = preflight(config, snapshot)
        except Refusal as exc:
            result['enable_preflight'] = str(exc)
    return result


def installed_backend_check():
    if Path(__file__).absolute() != INSTALL_DIR / 'backend.py':
        raise Refusal('Privileged operations must use the installed /opt/softrouter/backend.py.')
    checked_root_path(Path('/opt'), directory=True)
    checked_root_path(INSTALL_DIR, directory=True)
    checked_root_path(INSTALL_DIR / 'backend.py')


def installed_payload_check():
    # package-end is called only after the installer has copied the complete payload.
    for name in ('app.py', 'backend.py', 'uninstall.sh', 'config.example.json', 'README.md', 'VERSION', 'LICENSE', 'build-info.txt'):
        checked_root_path(INSTALL_DIR / name)
    for path in ('/usr/share/applications/softrouter.desktop', '/usr/share/pixmaps/softrouter.png'):
        checked_root_path(Path(path))


def package_begin(store):
    # Caller holds Store.lock, the same lock used throughout enable/disable.
    if store.read() is not None:
        raise Refusal('Disable or recover the owned profile before changing application files; ownership journal retained.')
    marker = store.maintenance()
    if marker is None:
        marker = dict(schema=1, kind='softrouter_package_maintenance', token=str(uuid.uuid4()))
        store.write_maintenance(marker)
    return dict(status='maintenance', detail='Sharing is blocked until the complete installed payload passes package-end. '
                'Removal or interruption leaves the private maintenance marker in place.')


def package_end(store):
    # main verifies the installed payload before calling this under Store.lock.
    if store.read() is not None:
        raise Refusal('Ownership journal exists; maintenance marker retained for recovery.')
    if store.maintenance() is not None:
        store.clear_maintenance()
    return dict(status='app_ready', detail='Installed payload checked and recognized maintenance marker cleared. No sharing was enabled.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('inspect', 'enable', 'disable', 'uninstall-check', 'package-begin', 'package-end'))
    args = parser.parse_args()
    try:
        data = None
        if args.action in ('enable', 'inspect') and not sys.stdin.isatty():
            text = sys.stdin.read(8193)
            if len(text) > 8192:
                raise Refusal('Configuration input exceeded 8192 characters.')
            if text.strip():
                data = decode(text)
        if args.action == 'inspect':
            result = inspect_result(System(), data)
        else:
            if os.geteuid() != 0:
                raise Refusal('Use the installed GUI administrator prompt for network changes.')
            installed_backend_check()
            store = Store()
            with store.lock():
                if args.action == 'package-begin':
                    result = package_begin(store)
                elif args.action == 'package-end':
                    installed_payload_check()
                    result = package_end(store)
                elif args.action == 'uninstall-check':
                    if store.read() is not None:
                        raise Refusal('Disable the owned profile successfully before uninstalling; recovery journal is retained.')
                    result = {'status': 'safe_to_uninstall'}
                else:
                    manager = Manager(System(), store)
                    result = manager.enable(data) if args.action == 'enable' else manager.disable()
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except (Refusal, OSError, KeyError, TypeError, ValueError) as exc:
        print(json.dumps({'status': 'attention', 'error': str(exc)}, ensure_ascii=False, indent=2))
        return 1


if __name__ == '__main__':
    sys.exit(main())
