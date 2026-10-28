"""Verify the consolidated Quartus project and independent Pi/web inputs."""
from pathlib import Path
import argparse
import hashlib
import json
import re
from check_runtime import check as check_runtime

def check(root, verify_manifest=False):
    root=root.resolve()
    assert [p.name for p in root.glob('*.qpf')]==['de0cv_chess.qpf'], 'Expected one Quartus project'
    assert [p.name for p in root.glob('*.qsf')]==['de0cv_chess.qsf'], 'Expected one Quartus settings file'
    qsf=(root/'de0cv_chess.qsf').read_text()
    assert '-name DEVICE 5CEBA4F23C7' in qsf, 'Wrong device'
    assert not re.search(r'-to\s*\{',qsf), 'QSF bus-node names must use native settings-file syntax'
    standards=set(re.findall(r'^set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to (\S+)$',qsf,re.M))
    assert standards=={'CLOCK_50','RESET_N','SPI_SCLK','SPI_MOSI','SPI_MISO','SPI_CS_N','IRQ_N','KEY[*]','LEDR[*]',
                       'HEX0[*]','HEX1[*]','HEX2[*]','HEX3[*]','HEX4[*]','HEX5[*]'},'Incomplete I/O standards'
    inputs=re.findall(r'^set_global_assignment -name (VHDL_FILE|SDC_FILE)\s+(.+)$',qsf,re.M)
    assert len(inputs)==10, 'Expected nine RTL files and one SDC'
    expected_rtl={'chess_pkg.vhd','chess_cell_memory.vhd','chess_spatial.vhd','chess_search_memory.vhd',
                  'chess_see.vhd','chess_engine.vhd','spi_target.vhd','chess_spi_bridge.vhd','de0cv_chess.vhd'}
    assert {Path(name).name for kind,name in inputs if kind=='VHDL_FILE'}==expected_rtl, 'Incomplete advanced engine sources'
    for kind,name in inputs:
        name=name.strip().strip('"');path=(root/name).resolve()
        assert not Path(name).is_absolute() and path.is_relative_to(root) and path.is_file(),f'External/missing {kind}: {name}'
        if kind=='VHDL_FILE':
            assert 'M9K' not in path.read_text(),f'MAX 10 RAM hint in Cyclone V source: {name}'
    bridge=(root/'rtl/chess_spi_bridge.vhd').read_text()
    assert 'CLOCK_HZ=>CLOCK_HZ' in bridge, 'Engine clock must follow SPI bridge clock'
    assert 'PAWN_LANES=>1' in bridge, 'DE0-CV profile requires the single pawn-file lane'
    pins=re.findall(r'^set_location_assignment (\S+) -to (\S+)',qsf,re.M)
    assert len(pins)==61 and len({pin for pin,_ in pins})==61,'Incomplete or duplicated pin assignments'
    mapping={name:pin for pin,name in pins}
    assert {name:mapping[name] for name in ['CLOCK_50','RESET_N','SPI_SCLK','SPI_MOSI','SPI_MISO','SPI_CS_N','IRQ_N']}=={
        'CLOCK_50':'PIN_M9','RESET_N':'PIN_P22','SPI_SCLK':'PIN_N16','SPI_MOSI':'PIN_B16','SPI_MISO':'PIN_M16','SPI_CS_N':'PIN_C16','IRQ_N':'PIN_D17'}
    check_runtime(root/'python')
    assert not (root/'rpi').exists() and not (root/'web').exists(), 'Runtime must be contained in python/'
    for folder in (root, *(root/name for name in ('rpi','tools','tests','rtl','sim','web','docs'))):
        assert not list(folder.glob('*.py')), f'Python sources must be consolidated under python/: {folder}'
    for source in (root/'python/spi_chess.py',root/'python/web_app.py'):
        assert not re.search(r'(?:referance|DE10LiteChess|chess_app)',source.read_text()),f'Reference dependency: {source}'
    if verify_manifest:
        manifest=json.loads((root/'output_files/build_manifest.json').read_text(encoding='utf-8-sig'))
        for name,expected_hash in manifest['sha256'].items():
            path=(root/name).resolve()
            assert not Path(name).is_absolute() and path.is_relative_to(root),f'External manifest input: {name}'
            assert path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest()==expected_hash,f'Release hash mismatch: {name}'
        print(f"PASS: {len(manifest['sha256'])} release hashes match.")
    print(f'PASS: one consolidated project, {len(inputs)} local inputs, 61 unique board pins, self-contained Pi/web files.')

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root',nargs='?',type=Path,default=Path(__file__).resolve().parents[1])
    parser.add_argument('--manifest',action='store_true',help='Verify packaged SHA-256 hashes.')
    args=parser.parse_args()
    check(args.root,args.manifest)
