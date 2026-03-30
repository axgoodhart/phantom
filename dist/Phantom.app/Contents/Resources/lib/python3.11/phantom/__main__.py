"""Entry point for `python -m phantom`."""

import sys


def main():
    cli_commands = {'list', 'run', 'record', 'stop', 'status', 'delete', 'rename', 'inspect'}

    # Check if any argument is a CLI command (to handle flags before the command)
    if any(arg in cli_commands for arg in sys.argv[1:]):
        from .cli import cli_main
        cli_main()
    else:
        from .app import main as gui_main
        gui_main()


main()
