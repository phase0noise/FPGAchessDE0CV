# Python tools

All Python sources, requirements and Python tests live in this folder. Keep
the complete project together: the service serves the sibling `web/` assets,
and project checks use the sibling Quartus and RTL files.

Install Python 3.10 or newer. From the project folder, run:

```powershell
powershell -ExecutionPolicy Bypass -File python/run.ps1 setup --dev
powershell -ExecutionPolicy Bypass -File python/run.ps1 test
powershell -ExecutionPolicy Bypass -File python/run.ps1 web
```

On Linux or Raspberry Pi:

```bash
bash python/run.sh setup --dev
bash python/run.sh test
bash python/run.sh web
```

The launcher creates `python/.venv/` and selects it automatically. There is
no activation step. Runtime-only installations can omit `--dev`. The Pi
installer, `bash rpi/setup.sh`, also enables SPI, installs the OS SPI package
and sets up the production service.

Every launcher resolves files from its own location. The project can be
renamed, copied, or placed in a folder containing spaces. A launcher can be
called from another working directory; relative tool arguments and generated
`.cache/` outputs resolve inside the project. The virtual environment is
local and ignored by Git and release packaging. Run `setup` again after
copying to another computer or changing your system Python; setup recreates
the environment. After moving an installed Pi service, rerun
`bash rpi/setup.sh` to regenerate systemd's required absolute paths.

| Command | Purpose |
| --- | --- |
| `setup [--dev]` | Install runtime or verification dependencies |
| `web [--host ADDRESS] [--port PORT]` | Start the development web server |
| `spi [--speed HZ] info` | Query real FPGA status over SPI |
| `test` | Run Python tests, including relocation checks |
| `check [PROJECT_FOLDER] [--manifest]` | Check local inputs and optionally release hashes |
| `fixtures [--count N]` | Generate independent rule fixtures |
| `search-fixtures`, `depth-fixtures`, `strength-fixtures` | Generate search fixtures |
| `check-cache`, `check-destinations`, `check-parallel`, `check-advancement`, `check-strength` | Check simulation logs; use `--help` for arguments |
| `serve` | Run the single-worker Gunicorn service on Linux |

Use `py python/run.py COMMAND` or `python3 python/run.py COMMAND` directly
if preferred. Set `PYTHON` to select an interpreter for either shell launcher.
Hardware commands require a Raspberry Pi, enabled SPI and the connected FPGA.
