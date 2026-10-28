import sys
import unittest
from pathlib import Path

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from spi_chess import SpiCommunicationError
from web_app import create_app

class Link:
    def __init__(self):self.calls=[];self.closed=False;self.status=0
    def close(self):self.closed=True
    def command(self,payload):
        self.calls.append(payload)
        status=bytearray(40);status[:4]=b'SCF2';status[15]=5
        status[36:40]=(50_000_000).to_bytes(4,'big')
        return self.status,bytes(status) if payload==b'\x00' else b'\x00'

class WebTests(unittest.TestCase):
    def setUp(self):
        self.link=Link();self.app=create_app(lambda:self.link);self.app.testing=True;self.client=self.app.test_client()
    def tearDown(self):self.app.extensions['chess_hardware'].close()
    def test_page_and_all_offline_assets(self):
        for name in ['','chess.js','fpga.js','app.js','style.css','pieces.png']:
            with self.client.get('/'+name) as response:
                self.assertEqual(response.status_code,200,name)
                self.assertEqual(response.headers['Cache-Control'],'no-store')
        self.assertEqual(self.link.calls,[])
    def test_command_json_contract(self):
        response=self.client.post('/api/command',data='00',content_type='text/plain')
        self.assertEqual(response.status_code,200);self.assertEqual(response.json['status'],0)
        self.assertTrue(response.json['payload'].startswith('53434632'));self.assertEqual(self.link.calls,[b'\0'])
    def test_invalid_and_oversize_bodies(self):
        for body in ['', '0', 'zz', '00  ', b'\xff\xff']:
            self.assertEqual(self.client.post('/api/command',data=body).status_code,400)
        self.assertEqual(self.client.post('/api/command',data='00'*82).status_code,413)
        self.assertEqual(self.link.calls,[])
    def test_maximum_length_command(self):
        self.assertEqual(self.client.post('/api/command',data='08'+'ff'*80).status_code,200)
        self.assertEqual(len(self.link.calls[0]),81)
    def test_engine_busy_status_preserved(self):
        self.link.status=3;response=self.client.post('/api/command',data='0b')
        self.assertEqual(response.status_code,200);self.assertEqual(response.json['status'],3)
    def test_missing_hardware_and_reconnect(self):
        attempts=[]
        def factory():
            attempts.append(1)
            if len(attempts)==1:raise SpiCommunicationError('No FPGA reply')
            return self.link
        client=create_app(factory).test_client()
        response=client.post('/api/command',data='00');self.assertEqual(response.status_code,503)
        self.assertIn('No FPGA',response.json['error'])
        self.assertEqual(client.post('/api/command',data='00').status_code,200)
    def test_failed_link_is_closed(self):
        class Broken(Link):
            def command(self,payload):raise SpiCommunicationError('SPI failure')
        link=Broken();app=create_app(lambda:link)
        self.assertEqual(app.test_client().post('/api/command',data='00').status_code,503)
        self.assertTrue(link.closed);self.assertIsNone(app.extensions['chess_hardware'].link)
    def test_health_checks_real_engine_signature(self):
        self.assertEqual(self.client.get('/healthz').status_code,200)
        self.assertEqual(self.link.calls,[b'\0'])
        self.link.status=3;self.assertEqual(self.client.get('/healthz').status_code,503)
    def test_paths_and_method(self):
        self.assertEqual(self.client.get('/python/spi_chess.py').status_code,404)
        self.assertEqual(self.client.get('/api/command').status_code,405)

if __name__=='__main__':unittest.main()
