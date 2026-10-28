/* Host-side transport and verification only. Never select an engine move here. */
(function(root){
  'use strict';
  const hex=bytes=>Array.from(bytes,b=>b.toString(16).padStart(2,'0')).join('');
  const unhex=text=>{
    if(typeof text!=='string'||text.length%2||!/^[0-9a-f]*$/i.test(text)) throw Error('Invalid Pi reply.');
    return Uint8Array.from(text.match(/../g)||[],b=>parseInt(b,16));
  };
  const u16=(a,i)=>(a[i]<<8)|a[i+1];
  const i16=(a,i)=>{const n=u16(a,i);return n&0x8000?n-0x10000:n;};
  const u32=(a,i)=>((a[i]*0x1000000)+(a[i+1]<<16)+(a[i+2]<<8)+a[i+3])>>>0;
  const same=(a,b)=>a.length===b.length&&Array.from(a).every((v,i)=>v===b[i]);
  class Fpga {
    constructor(fetcher=(...args)=>fetch(...args)) {this.fetcher=fetcher;this.queue=Promise.resolve();this.clockHz=50000000;}
    command(sub,data=[]) {
      const run=async()=>{
        const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),5000);
        try {
          const response=await this.fetcher('/api/command',{method:'POST',headers:{'Content-Type':'text/plain'},body:hex([sub,...data]),signal:controller.signal,cache:'no-store'});
          const value=await response.json();
          if(!response.ok) throw Error(value.error||`Pi HTTP ${response.status}`);
          if(value.status!==0) throw Error(value.status===3?'FPGA is busy or its position changed. Reconnect and retry.':`FPGA command ${sub} failed (status ${value.status}).`);
          return unhex(value.payload);
        } finally {clearTimeout(timer);}
      };
      const task=this.queue.catch(()=>{}).then(run);this.queue=task;return task;
    }
    async status() {
      const a=await this.command(0);
      const signature=String.fromCharCode(...a.slice(0,4));
      if(!((a.length===32&&signature==='SCF1'&&[3,4].includes(a[15]))||(a.length===40&&signature==='SCF2'&&a[15]===5))) throw Error('Load the matching DE0-CV FPGA image and Pi chess service.');
      if(this.version!==a[15]) this.maxDepth=undefined;
      this.version=a[15];
      if(this.version===5) {
        const frequency=u32(a,36);if(frequency<1000000||frequency>250000000) throw Error('Invalid FPGA clock frequency.');
        this.clockHz=frequency;
      } else {this.clockHz=50000000;this.maxDepth=this.version===4?6:3;}
      return {busy:!!a[4],done:!!a[5],check:!!a[6],turn:a[7],count:u16(a,8),move:u16(a,10),score:i16(a,12),state:a[14],cycles:u32(a,16)+(this.version===5?u32(a,32)*4294967296:0),generation:u32(a,20),version:a[15],clockHz:this.clockHz,searchDepth:a[15]>=4?a[28]:0,completedDepth:a[15]>=4?a[29]:0};
    }
    async setDepth(depth,timeSeconds=10) {
      if(![0,2,3,4,5,6,7,8].includes(depth)) throw Error('Unsupported search depth.');
      if(!Number.isInteger(timeSeconds)||timeSeconds<1||timeSeconds>60) throw Error('Think time must be 1 to 60 seconds.');
      if(this.version===undefined) await this.status();
      if(depth>3&&this.version<4) throw Error('Load the expanded DE0-CV FPGA image to use deeper search.');
      if(this.version===5&&this.maxDepth===undefined) await this.telemetry();
      if(depth>(this.maxDepth??(this.version===4?6:3))) throw Error('Unsupported search depth for this FPGA image. Load the eight-ply release.');
      const policy=await this.command(12,[0]);
      if(policy.length!==64) throw Error('Invalid policy page.');
      policy[10]=depth;
      if(this.version>=4) policy[40]=timeSeconds;
      await this.command(13,[0,...policy]);
    }
    async telemetry() {
      const a=await this.command(18);
      if(![10,20,128].includes(a.length)||(this.version===5&&a.length!==128)) throw Error('Invalid FPGA search telemetry.');
      const expanded=a.length>=20;
      const data={nodes:u32(a,0),cutoffs:u32(a,4),targetDepth:a[8],quiescence:a[9],
        depth:expanded?a[10]:a[8],cacheEnabled:expanded?!!(a[11]&2):false,
        budgetExpired:expanded&&!!(a[11]&1),clockHz:this.clockHz,
        cacheHits:expanded?u32(a,12):0,cacheStores:expanded?u32(a,16):0};
      if(a.length===128) {
        const clockHz=u32(a,20),maxDepth=a[24],pvLength=a[64],phaseCycles=Array.from({length:7},(_,i)=>u16(a,112+i*2)*4294967296+u32(a,36+i*4)),snapshotCycles=u16(a,110)*4294967296+u32(a,98);
        if(clockHz<1000000||clockHz>250000000||maxDepth<2||maxDepth>8||pvLength>14||
          phaseCycles.reduce((sum,n)=>sum+n,0)!==snapshotCycles) throw Error('Invalid FPGA capabilities or phase counters.');
        this.clockHz=clockHz;this.maxDepth=maxDepth;
        Object.assign(data,{clockHz,maxDepth,tacticalDepth:a[25],evalLanes:a[26],clockDivide:a[27],
          cacheCutoffs:u32(a,28),rootResearches:u32(a,32),phaseCycles,snapshotCycles,
          pv:Array.from({length:pvLength},(_,i)=>u16(a,65+i*2)),features:a[93],
          staticKing:i16(a,94),staticMobility:i16(a,96),seeCalls:u32(a,102),seeCycles:u32(a,106),queueLanes:a[126]});
      }
      return data;
    }
    async evaluate(game,{cancelled=()=>false,progress=()=>{},stage=()=>{},depth=5,timeSeconds=10}={}) {
      const position=game.position,expected=position.positionBytes(),legal=position.legalMoves();
      try {
        stage('upload');
        await this.command(3);await this.setDepth(depth,timeSeconds);await this.command(1,expected);
        const recent=game.history.slice(-8).reverse().map(h=>h.move);
        await this.command(17,[recent.length,...recent.flatMap(m=>[m>>8,m&255])]);
        if(cancelled()) throw Error('Stopped.');
        await this.command(2);stage('field');
        const deadline=Date.now()+180000;
        let status,telemetry=null,lastSample=0;
        do {
          if(cancelled()) throw Error('Stopped.');
          if(Date.now()>deadline) throw Error('FPGA search timed out. Try a shorter lookahead.');
          status=await this.status();
          const sampled=Date.now()-lastSample>=500||(!status.busy&&status.done);
          if(sampled) {telemetry=await this.telemetry();lastSample=Date.now();}
          progress({...status,telemetry,sampled});
          if(!status.busy&&status.done) break;
          await new Promise(resolve=>setTimeout(resolve,120));
        } while(true);
        stage('verify');
        if(status.count>256) throw Error('Invalid FPGA candidate count.');
        if(!same(await this.command(5),expected)) throw Error('The FPGA position changed during search.');
        const actual=[],candidates=[];
        for(let page=0;page<Math.ceil(status.count/16);page++) {
          const a=await this.command(7,[page]);
          if(a.length!==64) throw Error('Invalid FPGA candidate page.');
          for(let i=0;i<16&&actual.length<status.count;i++) {
            const move=u16(a,i*4);actual.push(move);candidates.push({move,score:i16(a,i*4+2)});
          }
          if(status.version===5) {
            const meta=await this.command(19,[page]);
            if(meta.length!==16) throw Error('Invalid FPGA candidate metadata.');
            for(let i=0;i<16&&page*16+i<status.count;i++) {
              const candidate=candidates[page*16+i],kind=meta[i]>>6;
              if(kind>2||(meta[i]&15)!==status.completedDepth) throw Error('FPGA candidate belongs to an incomplete iteration.');
              candidate.bound=['exact','upper','lower'][kind];candidate.depth=meta[i]&15;
              if(kind===2||candidate.score>status.score) throw Error('FPGA candidate bounds do not establish the selected move.');
            }
          }
        }
        const sorted=values=>values.slice().sort((a,b)=>a-b);
        if(!same(sorted(actual),sorted(legal))||new Set(actual).size!==actual.length) throw Error('FPGA legal moves disagree with the browser. No move was played.');
        if(!legal.length) return {...telemetry,move:null,cycles:status.cycles,nodes:0,candidates,parts:[],field:null};
        if(!actual.includes(status.move)) throw Error('FPGA selected a move absent from its legal set.');
        if(status.version===5&&candidates.find(c=>c.move===status.move).bound!=='exact') throw Error('FPGA selected an inexact move.');
        const pvSan=[];
        if(telemetry?.pv?.length) {
          if(telemetry.pv[0]!==status.move) throw Error('FPGA continuation does not match the selected move.');
          const replay=position.clone();
          for(const move of telemetry.pv) {
            if(!replay.legalMoves().includes(move)) throw Error('FPGA continuation contains an illegal move.');
            pvSan.push(replay.san(move));replay.make(move);
          }
        }
        const field=await this.command(4);
        if(field.length!==80) throw Error('Invalid FPGA field snapshot.');
        const index=actual.indexOf(status.move),explanations=await this.command(14,[Math.floor(index/4)]),offset=(index%4)*18;
        if(explanations.length!==72||u16(explanations,offset)!==status.move||i16(explanations,offset+2)!==status.score) throw Error('FPGA explanation does not match its selected move.');
        const parts=Array.from({length:7},(_,i)=>i16(explanations,offset+4+i*2));
        if(cancelled()) throw Error('Stopped.');
        stage('commit');
        const g=status.generation,m=status.move;
        await this.command(11,[g>>>24,(g>>>16)&255,(g>>>8)&255,g&255,m>>8,m&255]);
        const result=position.clone().make(m).positionBytes();
        if(!same(await this.command(5),result)) throw Error('FPGA move commit did not match the expected board. Reconnect to retry.');
        return {...telemetry,move:m,cycles:status.cycles,score:status.score,candidates,parts,pvSan,
          field:Array.from(field.slice(16),n=>n>127?n-256:n),
          attacks:{white:Array.from(field.slice(0,8)),black:Array.from(field.slice(8,16))}};
      } catch(error) {
        try {await this.command(3);} catch(_) {}
        throw error;
      }
    }
  }
  if(typeof module!=='undefined'&&module.exports) module.exports={Fpga,hex,unhex};
  root.FpgaChess={Fpga};
})(typeof globalThis!=='undefined'?globalThis:this);
