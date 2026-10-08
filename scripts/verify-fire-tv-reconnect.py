#!/usr/bin/env python3
"""Exercise trusted Connect/Disconnect against a real TV and running Mac server.

Usage: python3 scripts/verify-fire-tv-reconnect.py --cycles 50 --serial IP:5555
Requires an already paired receiver, ADB, and the Mac app running. Never clears
credentials or restarts either app. Records authentication and playback-clock
startup rather than treating a successful tap as a successful connection.
"""
import argparse
import json
import re
import subprocess
import tempfile
import time
import xml.etree.ElementTree as ET
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cycles', type=int, default=50)
    parser.add_argument('--serial')
    parser.add_argument('--output', default='/tmp/fire-tv-reconnect-results.json')
    args = parser.parse_args()
    adb = ['adb'] + (['-s', args.serial] if args.serial else [])

    def command(*parts):
        return subprocess.check_output(adb + list(parts), text=True, timeout=20)

    def ui():
        command('shell', 'uiautomator', 'dump', '/sdcard/frames-reconnect-ui.xml')
        raw = command('exec-out', 'cat', '/sdcard/frames-reconnect-ui.xml')
        start = raw.find('<?xml')
        end = raw.find('</hierarchy>') + len('</hierarchy>')
        if start < 0:
            raise RuntimeError('No UI hierarchy returned')
        return ET.fromstring(raw[start:end])

    def button(prefix, timeout=20):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for node in ui().iter('node'):
                if (node.get('text', '').lower().startswith(prefix.lower()) and
                        node.get('enabled') == 'true' and node.get('clickable') == 'true'):
                    coords = list(map(int, re.findall(r'\d+', node.get('bounds'))))
                    return ((coords[0] + coords[2]) // 2, (coords[1] + coords[3]) // 2)
            time.sleep(.5)
        raise RuntimeError(f'Button not available: {prefix}')

    def tap(coords):
        command('shell', 'input', 'tap', str(coords[0]), str(coords[1]))

    results = []
    output = Path(args.output)
    with tempfile.NamedTemporaryFile(mode='w', suffix='.log') as writer:
        log = open(writer.name)
        reader = subprocess.Popen(adb + ['logcat', '-T', '1', '-v', 'brief',
                                        'FireTVProtocol:I', 'FireTVMedia:I', 'AndroidRuntime:E', '*:S'],
                                  stdout=writer, stderr=subprocess.STDOUT, text=True)
        try:
            # BACK restores hidden playback controls without exiting the app.
            if not any(n.get('text', '').lower() == 'disconnect' for n in ui().iter('node')):
                command('shell', 'input', 'keyevent', '4')
            # Start from idle even if the previous test left playback running.
            disconnect = button('Disconnect')
            tap(disconnect)
            time.sleep(.5)
            connect = button('Connect to ')
            for cycle in range(1, args.cycles + 1):
                if cycle % 10 == 0:
                    connect = button('Connect to ')
                offset = log.seek(0, 2)
                started = time.monotonic()
                tap(connect)
                deadline = started + 30
                success = False
                transcript = ''
                while time.monotonic() < deadline:
                    log.seek(offset)
                    transcript = log.read()
                    if ('authentication succeeded' in transcript and
                            'playback clock started' in transcript):
                        success = True
                        break
                    if 'FATAL EXCEPTION' in transcript:
                        break
                    time.sleep(.25)
                elapsed = round(time.monotonic() - started, 2)
                results.append({'cycle': cycle, 'success': success,
                                'seconds_to_audio_clock': elapsed})
                output.write_text(json.dumps(results, indent=2) + '\n')
                print(f'Cycle {cycle}/{args.cycles}: {"PASS" if success else "FAIL"} ({elapsed}s)', flush=True)
                if not success:
                    raise RuntimeError('Authentication/audio-clock startup failed:\n' + transcript[-3000:])
                tap(disconnect)
                time.sleep(.5)
        finally:
            reader.terminate()
            reader.wait(timeout=10)
            log.close()
    print(f'Passed {len(results)} cycles; results: {output}', flush=True)


if __name__ == '__main__':
    main()
