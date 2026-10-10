#!/usr/bin/env python3
"""Real-device recovery tests. Requires a paired TV, ADB, and installed Mac app.

Temporarily suspends the Mac server (always resumes in finally), restarts the Mac
app, then exercises Fire TV app and in-app restarts. It never clears credentials.
"""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time
import xml.etree.ElementTree as ET


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial')
    parser.add_argument('--mac-app', default='/Applications/macOSFramesToFireTV.app')
    parser.add_argument('--output', default='/tmp/fire-tv-recovery-results.json')
    args = parser.parse_args()
    adb = ['adb'] + (['-s', args.serial] if args.serial else [])
    binary = str(Path(args.mac_app) / 'Contents/MacOS/macOSFramesToFireTV')
    results = []

    def command(*parts):
        return subprocess.check_output(adb + list(parts), text=True, timeout=20)

    def mac_pid():
        value = subprocess.check_output(['pgrep', '-f', '^' + re.escape(binary) + '$'], text=True).strip()
        return int(value)

    def tap(text, exact=False):
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            command('shell', 'uiautomator', 'dump', '/sdcard/frames-recovery-ui.xml')
            raw = command('exec-out', 'cat', '/sdcard/frames-recovery-ui.xml')
            root = ET.fromstring(raw)
            if text.lower() == 'disconnect' and not any(
                    n.get('text', '').lower() == 'disconnect' for n in root.iter('node')):
                command('shell', 'input', 'keyevent', '4')
                continue
            for node in root.iter('node'):
                label = node.get('text', '').lower()
                matches = label == text.lower() if exact else label.startswith(text.lower())
                if matches and node.get('enabled') == 'true' and (exact or node.get('clickable') == 'true'):
                    x1, y1, x2, y2 = map(int, re.findall(r'\d+', node.get('bounds')))
                    command('shell', 'input', 'tap', str((x1+x2)//2), str((y1+y2)//2))
                    return
            time.sleep(.5)
        raise RuntimeError('UI action unavailable: ' + text)

    with tempfile.NamedTemporaryFile(mode='w', suffix='.log') as writer, open(writer.name) as reader:
        logs = subprocess.Popen(adb + ['logcat', '-T', '1', '-v', 'brief',
                                      'FireTVProtocol:I', 'FireTVMedia:I', 'AndroidRuntime:E', '*:S'],
                                stdout=writer, stderr=subprocess.STDOUT)

        def mark():
            return reader.seek(0, 2)

        def playback(test, offset, started, timeout=45):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                reader.seek(offset)
                text = reader.read()
                if 'FATAL EXCEPTION' in text:
                    raise RuntimeError(test + ': receiver crashed')
                if 'authentication succeeded' in text and 'playback clock started' in text:
                    result = {'test': test, 'success': True,
                              'seconds_to_audio_clock': round(time.monotonic()-started, 2)}
                    results.append(result)
                    Path(args.output).write_text(json.dumps(results, indent=2) + '\n')
                    print(json.dumps(result), flush=True)
                    return
                time.sleep(.25)
            raise RuntimeError(test + ': no authenticated playback within deadline')

        try:
            tap('Disconnect', exact=True)
            offset, started = mark(), time.monotonic()
            tap('Connect to ')
            playback('trusted_connect', offset, started)

            pid = mac_pid()
            offset = mark()
            os.kill(pid, signal.SIGSTOP)
            try:
                time.sleep(15)  # longer than the negotiated 12-second liveness deadline
            finally:
                os.kill(pid, signal.SIGCONT)
            playback('silent_server_stall_auto_recovery', offset, time.monotonic())

            offset = mark()
            os.kill(mac_pid(), signal.SIGTERM)
            time.sleep(3)
            started = time.monotonic()
            subprocess.run(['open', args.mac_app], check=True)
            playback('mac_restart_auto_recovery', offset, started)

            command('shell', 'am', 'force-stop', 'com.aryanrogye.iosfiretv')
            command('shell', 'am', 'start', '-n', 'com.aryanrogye.iosfiretv/.MainActivity')
            offset, started = mark(), time.monotonic()
            tap('Connect to ')
            playback('fire_tv_app_restart_trusted_connect', offset, started)

            tap('More', exact=True)
            tap('Restart receiver', exact=True)
            offset, started = mark(), time.monotonic()
            tap('Connect to ')
            playback('fire_tv_in_app_restart_trusted_connect', offset, started)
        finally:
            logs.terminate()
            logs.wait(timeout=10)
    print('Recovery tests passed; results: ' + args.output, flush=True)


if __name__ == '__main__':
    main()
