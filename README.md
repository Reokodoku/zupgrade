# zupgrade

zupgrade is a tool for downloading and managing zig compilers.

To learn how to use the program, execute it (and its subcommands) with the `--help` flag.

## Config file

See `src/Config.zig` for configuration details.

## Environment variables

You can set the `ZUPGRADE_DATA_DIR` env to specify the data directory used by the program. By default, it is set to `$HOME/.zupgrade`.
