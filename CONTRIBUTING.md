# Contributing

Keep changes focused and describe the user-visible behavior they improve. Include the relevant verification command and result in a pull request.

```sh
make build
make test
```

Useful areas include native interface improvements, additional mesh formats, printer-profile validation and settings coverage. A new printer profile should retain its source and be tested against real generated paths, not only a successful engine exit code.

Do not commit downloaded installers, generated app bundles, local logs or machine-specific paths. Keep upstream notices intact. Physical print results should identify the printer, filament and settings used, without treating file-generation tests as physical validation.
