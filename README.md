# Build Notes (pyenv + py2app)

## Python version

Build with the same Python you develop against. The current bundle in
`dist/` was built with **Python 3.14**; the `.venv` in this repo matches.
If you recreate the environment, keep the interpreter consistent — the
pynput main-thread workaround in `phantom/app.py` and the pyobjc pins are
sensitive to the interpreter/macOS combination, so re-test recording after
any Python upgrade.

```bash
# from project root
python -m venv .venv
source .venv/bin/activate
python -m pip install -U pip setuptools wheel
python -m pip install -r requirements.txt
```

## Build production app

```bash
# requires setup.py with py2app config
python setup.py py2app
```

Note: `setup.py` references `Phantomicon.icns` in the project root — do not
delete or rename it without updating `setup.py`, or the build will break.

## Output
- App bundle: `dist/*.app`
- Build artifacts: `build/`

## Clean rebuild
```bash
rm -rf build dist
python setup.py py2app
```

## Signing & notarization (required for distribution)

An unsigned bundle will be blocked by Gatekeeper on other Macs, and because
Phantom depends on Accessibility/Automation permissions, ad-hoc signatures
mean users must re-grant permissions after every update (TCC ties grants to
the code signature). Sign with a stable Developer ID and notarize:

```bash
# 1. Sign everything in the bundle with hardened runtime
codesign --force --deep --options runtime \
  --sign "Developer ID Application: YOUR NAME (TEAMID)" \
  dist/Phantom.app

# 2. Verify
codesign --verify --strict --verbose=2 dist/Phantom.app

# 3. Zip and submit for notarization (requires notarytool keychain profile)
ditto -c -k --keepParent dist/Phantom.app dist/Phantom.zip
xcrun notarytool submit dist/Phantom.zip \
  --keychain-profile "AC_PASSWORD" --wait

# 4. Staple the ticket
xcrun stapler staple dist/Phantom.app
```

## First-run permissions

Phantom needs **Accessibility** (record + replay input) and **Automation →
System Events** (window restore). The in-app permission panel sequences the
two system prompts. Window-title capture additionally benefits from
**Screen Recording** permission; without it, workflows fall back to
positioning each app's front window.
