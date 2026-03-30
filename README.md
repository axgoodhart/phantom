# Build Notes (pyenv + py2app)

## Activate pyenv + venv
```bash
# from project root
pyenv install -s 3.11.9
pyenv local 3.11.9
python -m venv .venv
source .venv/bin/activate
python -m pip install -U pip setuptools wheel py2app
```

## Build production app
```bash
# requires setup.py with py2app config
python setup.py py2app
```

## Output
- App bundle: `dist/*.app`
- Build artifacts: `build/`

## Clean rebuild
```bash
rm -rf build dist
python setup.py py2app
```
