"""
py2app build configuration for Phantom.

Build with:
    python setup.py py2app

This creates a standalone macOS .app bundle in the dist/ directory.
"""

import os
from setuptools import setup

# UI files to include as data
ui_dir = os.path.join('phantom', 'ui')
ui_files = [os.path.join(ui_dir, f) for f in os.listdir(ui_dir)]

APP = ['run.py']

DATA_FILES = [
    ('phantom/ui', ui_files),
]

OPTIONS = {
    'iconfile': 'Phantomicon.icns',
    'argv_emulation': False,
    'packages': [
        'phantom',
        'webview',
        'pynput',
        'ApplicationServices',
    ],
    'excludes': [
        'setuptools',
        'pkg_resources',
        'distutils',
        'modulegraph',
        'altgraph',
        'macholib',
        'py2app',
        'test',
        'unittest',
    ],
    'frameworks': [],
    'plist': {
        'CFBundleName': 'Phantom',
        'CFBundleDisplayName': 'Phantom',
        'CFBundleIdentifier': 'com.alexgoodhart.Phantom',
        'CFBundleVersion': '1.0.0',
        'NSHumanReadableCopyright': 'Copyright © 2026 https://alexgoodh.art',
        'CFBundleShortVersionString': '1.0.0',
        'LSMinimumSystemVersion': '13.0',
        'NSAppleEventsUsageDescription': (
            'Phantom needs to send Apple Events '
            'to manage window positions during workflow setup.'
        ),
        'NSAccessibilityUsageDescription': (
            'Phantom needs Accessibility access '
            'to record and replay input events.'
        ),
        'NSAppSleepDisabled': True,
        'LSUIElement': True,
        'LSBackgroundOnly': False,
    },
}

setup(
    name='Phantom',
    version='1.0.0',
    description='macOS input recording and replay tool',
    app=APP,
    data_files=DATA_FILES,
    options={'py2app': OPTIONS},
)
