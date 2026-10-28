# Copy this folder. Run the program.

Copy this entire folder to a Raspberry Pi running **Raspberry Pi OS Bookworm
or newer**, with Wi-Fi and the FPGA connected. The folder can be renamed.
Open a terminal inside it and run:

```bash
python3 run.py
```

Join **DE0CV-Chess**, password **fpgachess**, and open
**http://10.42.0.1:8080**.

The app starts its web server first, then activates its own Wi-Fi hotspot.
It stays running if changing Wi-Fi disconnects the terminal's SSH session.
Python libraries are bundled in `vendor/`; normal startup needs no pip,
virtual environment, dependency download or separate installation command.
The FPGA programming image must already be loaded.

The Pi's existing NetworkManager manages the hotspot and hands out client
addresses. If its DHCP component is missing, startup installs only
`dnsmasq-base`. The Pi may ask for sudo authentication to enable SPI,
configure Wi-Fi or repair an older installation's chess service file.
Use a Pi with access-point-capable Wi-Fi and its wireless country configured.
If SPI was disabled, a one-time reboot may be needed for the device to appear.

## Everyday commands

```bash
python3 run.py                 # Start the app and its fixed-address Pi hotspot
python3 run.py status          # Show whether this folder's app is running
python3 run.py stop            # Stop it and restore the prior Wi-Fi connection
python3 run.py --lan           # Use your existing network without changing Wi-Fi
python3 run.py --autostart     # Also install the corrected service for boot startup
```

Normal startup repairs an existing `de0cv-chess.service` left by an older
installation. It generates paths from this folder, validates the new unit,
replaces the old unit and reloads systemd. The invalid quoted
`WorkingDirectory` setting is removed entirely. A fresh manual launch does
not require installing a chess systemd service.

Custom hotspot settings:

```bash
python3 run.py --ssid MyChess --password mychesspassword
```

On Windows, `py run.py` starts the same program on your existing LAN.
The program prints the usable addresses. The default port is **8080**.
Keep one copy running per FPGA; another program must not own SPI0/CE0.

`bash setup.sh` and `bash run.sh` are compatibility shortcuts for the same
program. To run the server in the foreground, use `python3 run.py web`;
this mode uses the existing network and stops with Ctrl+C.

## Sharing and development

Share this complete folder or `DE0CVChessPython.zip`. Include `vendor/`
and `web/`. Do not include local `.venv/`, `.cache/` or `__pycache__/`
directories. All app paths are derived from the program's location.

The Linux SPI fallback uses the kernel interface directly if the optional
`spidev` Python extension is absent. It works with the same SPI register
transport; all chess logic remains on the FPGA.

Developer commands are optional: `python3 run.py setup --dev` installs the
independent chess fixture generator; `python3 run.py test` runs Python checks;
`python3 run.py check` checks the copied folder. FPGA development checks
use `check-project` and require the rest of the FPGA project.
