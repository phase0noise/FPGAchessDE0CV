import struct
import sys
import threading
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from spi_chess import ChessSPI, SpiCommunicationError, SpiDevice, crc16

class RegisterModel:
    """Test double for the documented mailbox; never a playable opponent."""
    def __init__(self, result=b'\x53\x43\x46\x31', status=0):
        self.mem=bytearray(256)
        self.mem[:8]=bytes([0xC5,3,7,0])+b'CHS3'
        self.result=result;self.status=status;self.reply=b''
        self.last=None;self.executions=[];self.pages=[];self.closed=False
        self.corrupt_upload=0;self.corrupt_reply=0;self.wrong_sequence=False;self.oversize=False
        self.stuck=False
    def close(self):self.closed=True
    def read(self, address, length=1):
        if address==3 and self.stuck:return b'\x01'
        if address==0x80:
            page=self.mem[0x18];self.pages.append(page)
            return self.reply[page*128:page*128+length]
        if address==0x1A and self.corrupt_reply:
            self.corrupt_reply-=1
            return bytes([self.mem[0x1A]^1,self.mem[0x1B]])
        return bytes(self.mem[address:address+length])
    def write(self,address,data):
        data=bytes(data);self.mem[address:address+len(data)]=data
        if address==0x20 and self.corrupt_upload:
            self.mem[address]^=1;self.corrupt_upload-=1
        if address==0x0F and data==b'\x5A':self.mem[3]=0
        if address==0x0F and data==b'\xA5':
            sequence,length=struct.unpack('!IB',self.mem[0x10:0x15])
            payload=bytes(self.mem[0x20:0x20+length]);checksum=int.from_bytes(self.mem[0x15:0x17],'big')
            valid=checksum==crc16(b'\x01'+bytes(self.mem[0x10:0x15])+payload)
            key=(sequence,payload)
            if not valid:status,result=5,b''
            elif key==self.last:return self._reply(sequence,self.status,self.result)
            else:
                self.executions.append((sequence,payload));self.last=key
                status,result=self.status,self.result
            self._reply(sequence,status,result)
    def _reply(self,sequence,status,result):
        self.reply=result
        header=struct.pack('!IBH',sequence+int(self.wrong_sequence),status,len(result))
        self.mem[8:15]=header;self.mem[3]=2
        self.mem[0x1A:0x1C]=struct.pack('!H',crc16(b'\x01'+header+result))
        if self.oversize:self.mem[0x0D:0x0F]=b'\x04\x01'

class SpiTests(unittest.TestCase):
    def test_crc_check_vector(self):self.assertEqual(crc16(b'123456789'),0x29B1)
    def test_command_and_reply_pages(self):
        raw=bytes(range(256))*4;model=RegisterModel(raw);link=ChessSPI(model,sequence=10)
        status,data=link.command(bytes(range(81)))
        self.assertEqual((status,data),(0,raw));self.assertEqual(model.pages,list(range(8)))
        self.assertEqual(model.executions,[(11,bytes(range(81)))])
    def test_reply_corruption_retries_same_sequence_once(self):
        model=RegisterModel(b'ack');model.corrupt_reply=1;link=ChessSPI(model,sequence=15)
        self.assertEqual(link.command(b'\x0A'),(0,b'ack'))
        self.assertEqual(model.executions,[(16,b'\x0A')])
    def test_upload_crc_rejection_retries_without_executing_garbage(self):
        model=RegisterModel(b'ack');model.corrupt_upload=1
        self.assertEqual(ChessSPI(model,sequence=0).command(b'\x0A'),(0,b'ack'))
        self.assertEqual(model.executions,[(1,b'\x0A')])
    def test_bad_identity_stops_before_command(self):
        model=RegisterModel();model.mem[1]=2
        with self.assertRaisesRegex(SpiCommunicationError,'identity'):ChessSPI(model).command(b'\x00')
        self.assertEqual(model.executions,[])
    def test_foreign_sequence_rejected(self):
        model=RegisterModel();model.wrong_sequence=True
        with self.assertRaisesRegex(SpiCommunicationError,'sequence'):ChessSPI(model).command(b'\x00')
    def test_oversize_reply_rejected(self):
        model=RegisterModel();model.oversize=True
        with self.assertRaisesRegex(SpiCommunicationError,'1024'):ChessSPI(model).command(b'\x00')
    def test_timeout_bounded(self):
        model=RegisterModel();model.stuck=True
        with self.assertRaisesRegex(SpiCommunicationError,'timed out'):ChessSPI(model,timeout=.002).command(b'\x00')
    def test_engine_error_is_returned_without_replaying(self):
        model=RegisterModel(b'\0',status=3)
        self.assertEqual(ChessSPI(model).command(b'\x0B'),(3,b'\0'));self.assertEqual(len(model.executions),1)
    def test_invalid_request_sizes(self):
        link=ChessSPI(RegisterModel())
        for payload in (b'',bytes(82)):
            with self.assertRaises(ValueError):link.command(payload)
    def test_threads_serialize_whole_mailbox_transaction(self):
        model=RegisterModel(b'ack');link=ChessSPI(model,sequence=1);results=[]
        threads=[threading.Thread(target=lambda n=n:results.append(link.command(bytes([n])))) for n in range(8)]
        for thread in threads:thread.start()
        for thread in threads:thread.join()
        self.assertEqual(len(results),8);self.assertEqual(len(model.executions),8)
        self.assertEqual([seq for seq,_ in model.executions],list(range(2,10)))
    def test_single_chip_select_frame(self):
        class Bus:
            def __init__(self):self.frames=[]
            def xfer2(self,frame):self.frames.append(frame);return [0,0,0x11,0x22][:len(frame)]
            def close(self):pass
        device=object.__new__(SpiDevice);device.spi=Bus();device.lock_file=None
        self.assertEqual(device.read(0x80,2),b'\x11\x22')
        device.write(0x10,b'\x01\x02');self.assertEqual(device.spi.frames,[[0x80,0x80,0,0],[0,0x10,1,2]])
        with self.assertRaises(ValueError):device.read(0xFF,2)
        device.close()

if __name__=='__main__':unittest.main()
