#!/usr/bin/env python3
"""Run Phantom -- routes to CLI or GUI based on arguments."""

import sys

_CLI_COMMANDS = {'list', 'run', 'record', 'stop', 'status', 'delete', 'rename', 'inspect'}

if any(arg in _CLI_COMMANDS for arg in sys.argv[1:]):
    from phantom.cli import cli_main
    cli_main()
else:
    from phantom.app import main
    main()
