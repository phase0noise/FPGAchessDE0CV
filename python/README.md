# Standalone Raspberry Pi chess app

**Copy only this folder to the Raspberry Pi.** It contains the Python app,
web board, dependencies, Pi installer and service template. Its parent folder
can have any name and does not need any other project files.

Open a terminal inside the copied folder and run as your normal Pi user:

```bash
bash setup.sh
```

This creates a Linux Python environment here, enables SPI, installs the
service and configures the hotspot. Join **DE0CV-Chess**, password
**fpgachess**, then open **http://10.42.0.1:8080**. Use
`bash setup.sh --no-hotspot` to keep your existing network, or
`bash setup.sh --ssid MyChess --password mychesspassword`.
The FPGA must already have the matching programming image loaded.

For manual use with Python 3.10 or newer, from inside this folder:

```powershell
powershell -ExecutionPolicy Bypass -File run.ps1 setup --dev
powershell -ExecutionPolicy Bypass -File run.ps1 test
powershell -ExecutionPolicy Bypass -File run.ps1 web
```

On Linux or Raspberry Pi:

```bash
bash run.sh setup --dev
bash run.sh test
bash run.sh web
```

The launcher selects the local `.venv/` automatically; activation is not
needed. Runtime-only installations can omit `--dev`. Always run setup on
the destination computer; Windows Python environments cannot run on a Pi.

Every launcher resolves files from its own location. This folder can be
renamed, copied, or placed in a folder containing spaces. A launcher can be
called from another working directory; relative tool arguments and generated
`.cache/` outputs resolve inside this folder. The virtual environment is
local and ignored by Git and release packaging. Run `setup` again after
copying to another computer or changing your system Python; setup recreates
the environment. After moving an installed Pi service, rerun
`bash setup.sh` from the new location to regenerate the installed service.
No source file contains a fixed checkout or home-directory path.

| Command | Purpose |
| --- | --- |
| `setup [--dev]` | Install runtime or verification dependencies |
| `web [--host ADDRESS] [--port PORT]` | Start the development web server |
| `spi [--speed HZ] info` | Query real FPGA status over SPI |
| `test` | Run Python tests, including relocation checks |
| `check` | Verify this standalone folder contains all runtime files |
| `fixtures [--count N]` | Generate independent rule fixtures |
| `search-fixtures`, `depth-fixtures`, `strength-fixtures` | Generate search fixtures |
| `check-cache`, `check-destinations`, `check-parallel`, `check-advancement`, `check-strength` | Check simulation logs; use `--help` for arguments |
| `serve` | Run the single-worker Gunicorn service on Linux |
| `check-project [PROJECT_FOLDER] [--manifest]` | Optional FPGA developer check; requires the full FPGA project |

Use `py run.py COMMAND` or `python3 run.py COMMAND` directly
if preferred. Set `PYTHON` to select an interpreter for either shell launcher.
Hardware commands require a Raspberry Pi, enabled SPI and the connected FPGA.
