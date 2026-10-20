#!/usr/bin/env python3
"""Isolated Linux WebRTC/TURN experiment; fixture gates are not Nexus auth."""
import argparse
import json
import pathlib
import subprocess
import threading
import time
import urllib.request
import uuid


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def http(base, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(base + path, data=data, headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=15) as response:
        return json.load(response)


def distribution(values):
    values = sorted(values)
    return {key: values[min(len(values)-1, int((len(values)-1)*q))] for key, q in [('p50', .5), ('p95', .95), ('p99', .99)]} if values else {}


class World:
    def __init__(self):
        self.prefix = 'realtime-poc-' + uuid.uuid4().hex[:8]
        self.names, self.urls = {}, {}
        self.refresh, self.done, self.errors = True, threading.Event(), []

    def start(self):
        command('docker', 'network', 'create', self.prefix)
        for role in ['turn', 'runner', 'agent']:
            name = self.prefix + '-' + role
            self.names[role] = name
            args = ['docker', 'run', '-d', '--name', name, '--network', self.prefix, '--cap-add=NET_ADMIN', '-p', '127.0.0.1::8080', 'cybros-e2e/realtime-transport:poc']
            args += ['-role', 'turn', '-relay-ip', name] if role == 'turn' else (['-runner'] if role == 'runner' else [])
            command(*args)
            port = command('docker', 'port', name, '8080/tcp').rsplit(':', 1)[1]
            self.urls[role] = 'http://127.0.0.1:' + port
            for attempt in range(100):
                try:
                    self.get(role)
                    break
                except Exception:
                    if attempt == 99:
                        raise
                    time.sleep(.1)
        self.thread = threading.Thread(target=self.heartbeat, daemon=True)
        self.thread.start()

    def heartbeat(self):
        while not self.done.is_set():
            if self.refresh:
                try:
                    for role in ['agent', 'runner']:
                        self.post(role, '/gate', {'Allow': True, 'ValidForMS': 1000})
                except Exception as error:
                    self.errors.append(str(error))
            self.done.wait(.2)

    def get(self, role):
        return http(self.urls[role], '/stats')

    def post(self, role, path, body):
        return http(self.urls[role], path, body)

    def connect(self, mode):
        connection = uuid.uuid4().hex
        started = time.monotonic()
        config = {'Mode': mode, 'Connection': connection, 'TURN': 'turn:' + self.names['turn'] + ':3478?transport=udp'}
        for role in ['agent', 'runner']:
            self.post(role, '/connect', config)
        offer = self.post('agent', '/offer', {})
        answer = self.post('runner', '/answer', offer)
        self.post('agent', '/remote', answer)
        for _ in range(100):
            stats = self.get('agent')
            if stats.get('control_state') == 'open':
                return {'connection': connection, 'setup_s': time.monotonic()-started, 'pair': stats['pair']}
            time.sleep(.1)
        raise RuntimeError('ICE connection failed: ' + json.dumps(stats))

    def close(self):
        self.done.set()
        if hasattr(self, 'thread'):
            self.thread.join(timeout=20)
        for name in self.names.values():
            subprocess.run(['docker', 'rm', '-f', name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(['docker', 'network', 'rm', self.prefix], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def measure(world, mode, mixed, samples, duration):
    connection = world.connect(mode)
    assert (connection['pair']['local'] == 'relay') == (mode == 'relay'), connection
    world.post('runner', '/load', {'Enabled': mixed})
    for _ in range(5):
        assert not world.post('agent', '/sample', {}).get('error')
    before = {role: world.get(role) for role in world.urls}
    started, raw = time.monotonic(), []
    for index in range(samples):
        raw.append(world.post('agent', '/sample', {}))
        time.sleep(max(0, started + duration*(index+1)/samples - time.monotonic()))
    elapsed = time.monotonic()-started
    after = {role: world.get(role) for role in world.urls}
    world.post('runner', '/load', {'Enabled': False})
    assert not world.errors, world.errors
    result = {'mode': mode, 'mixed': mixed, **connection, 'elapsed_s': elapsed, 'latency_ms': distribution([x['ms'] for x in raw]), 'raw': raw, 'before': before, 'after': after}
    result['cpu_cores'] = {role: (after[role]['process']['cpu_s']-before[role]['process']['cpu_s'])/elapsed for role in world.urls}
    result['relay_bytes'] = {key: after['turn'][key]-before['turn'][key] for key in ['rx', 'tx']}
    result['received_bytes_per_s'] = {key: (after['agent'][key]-before['agent'][key])/elapsed for key in ['terminal_bytes', 'media_bytes']}
    result['frame_rtt_ms'] = distribution(after['runner']['frame_rtt_ms'][len(before['runner']['frame_rtt_ms']):])
    print(json.dumps({key: value for key, value in result.items() if key not in ['raw', 'before', 'after']}), flush=True)
    return result


def failures(world):
    current = world.connect('auto')
    assert not world.post('agent', '/sample', {}).get('error')
    pid = world.get('runner')['pid']
    world.refresh = False
    time.sleep(1.3)
    before = world.get('runner')
    refused = world.post('agent', '/sample', {})
    assert refused.get('error') and not before['authorized'] and not before['child_exited']
    world.refresh = True
    time.sleep(.3)
    assert not world.post('agent', '/sample', {}).get('error')
    # Block peer-to-peer UDP, while leaving both peers' TURN path available.
    for role, other in [('agent', 'runner'), ('runner', 'agent')]:
        address = command('docker', 'inspect', '-f', '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}', world.names[other])
        command('docker', 'exec', world.names[role], 'iptables', '-A', 'OUTPUT', '-p', 'udp', '-d', address, '-j', 'DROP')
    fallback = world.connect('auto')
    assert 'relay' in [fallback['pair']['local'], fallback['pair']['remote']], fallback
    assert world.get('runner')['pid'] == pid
    assert not world.post('agent', '/sample', {}).get('error')
    before = world.get('runner')['applied']
    stale = world.post('agent', '/sample', {'Connection': current['connection']})
    assert stale.get('error') and world.get('runner')['applied'] == before
    world.refresh = False
    world.post('agent', '/gate', {'Terminal': True})
    world.post('runner', '/gate', {'Terminal': True})
    assert world.get('runner')['child_exited']
    assert world.post('agent', '/sample', {}).get('error')
    return {'gate_expiry_preserved_child': True, 'direct_blocked_fallback': fallback, 'reconnect_preserved_pid': True, 'stale_input_refused': True, 'fixture_stop_reaped_child': True, 'nexus_integration': False}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--samples', type=int, default=300)
    parser.add_argument('--duration', type=float, default=30)
    parser.add_argument('--rounds', type=int, default=2)
    parser.add_argument('--output', required=True)
    parser.add_argument('--delay-ms', type=float, default=0, help='netem delay on each container egress; relay has more hops')
    args = parser.parse_args()
    result, world = {'measurements': []}, World()
    path = pathlib.Path(args.output)
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        world.start()
        result['egress_delay_ms'] = args.delay_ms
        if args.delay_ms:
            for name in world.names.values():
                command('docker', 'exec', name, 'tc', 'qdisc', 'add', 'dev', 'eth0', 'root', 'netem', 'delay', str(args.delay_ms)+'ms')
        for round_index in range(args.rounds):
            for mode in (['auto', 'relay'] if round_index % 2 == 0 else ['relay', 'auto']):
                for mixed in [False, True]:
                    result['measurements'].append(measure(world, mode, mixed, args.samples, args.duration))
                    path.write_text(json.dumps(result, indent=2)+'\n')
                    assert not any(item.get('error') for item in result['measurements'][-1]['raw']), 'input failures retained in output'
        result['failures'] = failures(world)
    except Exception as error:
        result['error'] = repr(error)
        raise
    finally:
        path.write_text(json.dumps(result, indent=2)+'\n')
        world.close()
    print(json.dumps(result['failures']), flush=True)


if __name__ == '__main__':
    main()
