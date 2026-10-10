#!/usr/bin/env python3
"""Verify launcher re-entry and Home/return on a paired physical Fire TV.

Starts one fresh TV process using an explicit intent, then uses launcher intents
and Home without restarting the process. The Mac app is never restarted or paired.
Probes the Mac listener after Home to prove the hidden receiver released its slot.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import re
import socket
import struct
import subprocess
import tempfile
import time
import xml.etree.ElementTree as ET


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial')
    parser.add_argument('--cycles', type=int, default=8)
    parser.add_argument('--output', default='/tmp/fire-tv-lifecycle-results.json')
    args = parser.parse_args()
    adb = ['adb'] + (['-s', args.serial] if args.serial else [])
    component = 'com.aryanrogye.iosfiretv/.MainActivity'
    mac_pid = subprocess.check_output(['pgrep', '-f', '^/Applications/macOSFramesToFireTV.app/Contents/MacOS/macOSFramesToFireTV$'], text=True).strip()
    results = []

    def command(*parts):
        return subprocess.check_output(adb + list(parts), text=True, timeout=20)

    def launcher():
        command('shell', 'am', 'start', '-W', '-a', 'android.intent.action.MAIN', '-c',
                'android.intent.category.LEANBACK_LAUNCHER', '-n', component)

    def assert_one_activity():
        stack = command('shell', 'dumpsys', 'activity', 'activities')
        records = re.findall(r'^\s*\* Hist #\d+: ActivityRecord\{[^\n]*com\.aryanrogye\.iosfiretv/\.MainActivity', stack, re.M)
        assert len(records) == 1, f'Expected one receiver Activity; found {len(records)}'

    def connect():
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            command('shell', 'uiautomator', 'dump', '/sdcard/frames-lifecycle-test.xml')
            root = ET.fromstring(command('exec-out', 'cat', '/sdcard/frames-lifecycle-test.xml'))
            for node in root.iter('node'):
                if (node.get('text', '').lower().startswith('connect to ') and
                        node.get('clickable') == 'true' and node.get('enabled') == 'true'):
                    x1, y1, x2, y2 = map(int, re.findall(r'\d+', node.get('bounds')))
                    command('shell', 'input', 'tap', str((x1+x2)//2), str((y1+y2)//2))
                    return
            time.sleep(.25)
        raise RuntimeError('Connect button unavailable after returning from Home')

    def probe_released_mac_once():
        lines = subprocess.check_output(['lsof', '-a', '-p', mac_pid, '-iTCP', '-sTCP:LISTEN', '-Fn'], text=True).splitlines()
        port = int(next(line for line in lines if line.startswith('n')).rsplit(':', 1)[1])
        def read_all(peer, size):
            data = b''
            while len(data) < size:
                part = peer.recv(size-len(data))
                if not part:
                    raise RuntimeError('Mac rejected probe: receiver slot still occupied')
                data += part
            return data
        with socket.create_connection(('127.0.0.1', port), timeout=5) as peer:
            hello = {'type': 'hello', 'version': 1, 'receiverID': 'untrusted-lifecycle-probe',
                     'salt': base64.b64encode(os.urandom(16)).decode(),
                     'challenge': base64.b64encode(os.urandom(32)).decode(), 'features': []}
            body = b'\0' + json.dumps(hello).encode()
            peer.sendall(struct.pack('>I', len(body)) + body)
            response = read_all(peer, struct.unpack('>I', read_all(peer, 4))[0])
            assert json.loads(response[1:])['type'] == 'pairing_required'

    def probe_released_mac():
        # Socket/encoder cleanup is asynchronous after onStop. Require bounded
        # release, not a scheduling-dependent response at exactly one second.
        deadline = time.monotonic() + 5
        while True:
            try:
                probe_released_mac_once()
                return
            except (ConnectionResetError, EOFError, OSError, RuntimeError):
                if time.monotonic() >= deadline:
                    raise
                time.sleep(.2)

    with tempfile.NamedTemporaryFile(mode='w', suffix='.log') as writer, open(writer.name) as reader:
        logs = subprocess.Popen(adb + ['logcat', '-T', '1', '-v', 'brief',
                                      'FireTVProtocol:I', 'FireTVMedia:I', 'AndroidRuntime:E', '*:S'],
                                stdout=writer, stderr=subprocess.STDOUT)
        try:
            command('shell', 'am', 'force-stop', 'com.aryanrogye.iosfiretv')
            command('shell', 'am', 'start', '-W', '-n', component)
            tv_pid = command('shell', 'pidof', 'com.aryanrogye.iosfiretv').strip()
            for cycle in range(1, args.cycles + 1):
                offset = reader.seek(0, 2)
                connect()
                deadline = time.monotonic() + 20
                while time.monotonic() < deadline:
                    reader.seek(offset)
                    text = reader.read()
                    if 'authentication succeeded' in text and 'playback clock started' in text:
                        break
                    time.sleep(.25)
                else:
                    raise RuntimeError('Trusted playback did not start')
                launcher()
                launcher()
                assert_one_activity()
                command('shell', 'input', 'keyevent', '3')  # Home, not force-stop
                time.sleep(1)
                probe_released_mac()
                launcher()
                assert_one_activity()
                assert command('shell', 'pidof', 'com.aryanrogye.iosfiretv').strip() == tv_pid
                assert subprocess.check_output(['pgrep', '-f', '^/Applications/macOSFramesToFireTV.app/Contents/MacOS/macOSFramesToFireTV$'], text=True).strip() == mac_pid
                results.append({'cycle': cycle, 'success': True, 'activities': 1,
                                'background_session_released': True, 'same_tv_and_mac_processes': True})
                Path(args.output).write_text(json.dumps(results, indent=2) + '\n')
                print(f'Cycle {cycle}/{args.cycles}: PASS — single Activity, background slot released, trusted playback', flush=True)
        finally:
            logs.terminate()
            logs.wait(timeout=10)
    print('Lifecycle tests passed; results: ' + args.output, flush=True)


if __name__ == '__main__':
    main()
