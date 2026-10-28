# Bundled runtime libraries

Flask 3.1.3, Waitress 3.0.2 and their dependencies are included so the app runs
without pip, a virtual environment or an internet connection. Each package's
license is included in its dist-info directory.

Native extension binaries and generated console launchers are excluded.
MarkupSafe uses its pure Python fallback. The Linux SPI adapter also uses
Python's standard library when the optional python3-spidev package is absent.
