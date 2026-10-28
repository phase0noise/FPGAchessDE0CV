'use strict';
const assert=require('node:assert/strict');
const {Game,uci,decode}=require('../python/web/chess.js');
const {Fpga,hex,unhex}=require('../python/web/fpga.js');
assert.deepEqual(Array.from(unhex(hex([0,255,1,128]))),[0,255,1,128]);
assert.throws(()=>unhex('xz'));
function fixture({badLegal=false,badBoard=false,badExplanation=false,badBound=false,badPV=false,badClock=false,wideCycles=false,timeout=false,version=4}={}) {
  const game=new Game(),calls=[],policies=[];let position=game.position.clone(),generation=2,done=false,stopped=false,requestedDepth=5;
  const fetcher=async(url,request)=>{
    const a=unhex(request.body),sub=a[0];calls.push(sub);
    let out=[];
    switch(sub) {
      case 0: {
        out=new Uint8Array(version>=5?40:32);out.set([83,67,70,version>=5?50:49]);out[4]=timeout?1:0;out[5]=done?1:0;out[15]=version;
        if(version>=5) {new DataView(out.buffer).setUint32(36,55000000);if(wideCycles){out[35]=1;out[19]=17;}}
        out[28]=requestedDepth;out[29]=done?requestedDepth:0;
        const moves=position.legalMoves(),best=moves.find(m=>uci(m)==='e2e4')??moves[0];
        out[8]=moves.length>>8;out[9]=moves.length&255;out[10]=best>>8;out[11]=best&255;
        out[20]=generation>>>24;out[21]=(generation>>>16)&255;out[22]=(generation>>>8)&255;out[23]=generation&255;break;
      }
      case 1: generation++;break;
      case 2: done=true;break;
      case 3: stopped=true;done=false;break;
      case 4: out=new Uint8Array(80);out[16]=255;out[79]=127;break;
      case 5: out=position.positionBytes();if(badBoard)out[0]^=1;break;
      case 7: {
        out=new Uint8Array(64);const moves=position.legalMoves();
        for(let i=0;i<16;i++) {const move=moves[a[1]*16+i]||0;out[i*4]=move>>8;out[i*4+1]=move&255;}
        if(badLegal) out[0]=127;break;
      }
      case 11: {
        const move=(a[5]<<8)|a[6];assert.equal(move,position.legalMoves().find(m=>uci(m)==='e2e4'));
        position.make(move);break;
      }
      case 12: out=new Uint8Array(64);break;
      case 13:policies.push(Array.from(a.slice(2)));requestedDepth=a[12];out=[0];break;
      case 14: {
        out=new Uint8Array(72);const moves=position.legalMoves();
        for(let i=0;i<4;i++) {const move=moves[a[1]*4+i]||0;out[i*18]=move>>8;out[i*18+1]=move&255;}
        if(badExplanation) out.fill(255);break;
      }
      case 18:
        out=Uint8Array.from([0,0,1,0,0,0,0,4,5,4,5,2,0,0,0,12,0,0,0,34]);
        if(version>=5) {
          const expanded=new Uint8Array(128);expanded.set(out);out=expanded;
          out[8]=requestedDepth;out[10]=done?requestedDepth:0;
          new DataView(out.buffer).setUint32(20,badClock?0:55000000);out[24]=8;out[25]=10;out[26]=4;out[27]=4;
          out[64]=done?1:0;const move=position.legalMoves().find(m=>uci(m)===(badPV?'a2a3':'e2e4'));
          out[65]=move>>8;out[66]=move&255;out[93]=15;
          if(wideCycles){out[111]=1;out[101]=17;out[113]=1;out[39]=17;}
        }break;
      case 19:
        out=new Uint8Array(16);for(let i=0;i<16;i++) {
          const move=position.legalMoves()[a[1]*16+i];out[i]=requestedDepth|((uci(move)==='e2e4'&&!badBound)?0:64);
        }break;
      default:out=[0];
    }
    return {ok:true,json:async()=>({status:0,payload:hex(out)})};
  };
  return {game,calls,policies,device:new Fpga(fetcher),stopped:()=>stopped};
}
(async()=>{
  const good=fixture();const evaluation=await good.device.evaluate(good.game);
  assert.equal(uci(evaluation.move),'e2e4');assert.equal(evaluation.nodes,256);
  assert.equal(evaluation.depth,5);assert.equal(evaluation.cacheHits,12);assert.equal(evaluation.cacheStores,34);
  assert.equal(evaluation.cutoffs,4);assert.equal(evaluation.quiescence,4);assert(evaluation.cacheEnabled);
  assert.equal(evaluation.field[0],-1);assert.equal(evaluation.field[63],127);
  assert.equal(evaluation.candidates.length,20);assert.equal(evaluation.parts.length,7);
  assert.equal(good.policies[0][10],5);assert.equal(good.policies[0][40],10);
  const deep=fixture();await deep.device.setDepth(6,30);
  assert.equal(deep.policies[0][10],6);assert.equal(deep.policies[0][40],30);
  await assert.rejects(()=>deep.device.setDepth(7),/Unsupported/);
  await assert.rejects(()=>deep.device.setDepth(6,61),/Think time/);
  const legacy=fixture({version:3});await assert.rejects(()=>legacy.device.setDepth(5),/expanded DE0-CV/);
  await legacy.device.setDepth(3);
  assert(good.calls.includes(7));assert(good.calls.includes(11));
  const parallel=fixture({version:5}),advanced=await parallel.device.evaluate(parallel.game,{depth:8});
  assert.equal(advanced.clockHz,55000000);assert.equal(advanced.evalLanes,4);assert.equal(advanced.maxDepth,8);
  assert.equal(advanced.depth,8);assert.equal(advanced.candidates.find(c=>c.move===advanced.move).bound,'exact');
  assert(advanced.candidates.some(c=>c.bound==='upper'));assert.deepEqual(advanced.pvSan,['e4']);
  assert(parallel.calls.includes(19));assert.equal(parallel.policies[0][10],8);
  const wide=fixture({version:5,wideCycles:true});
  assert.equal((await wide.device.status()).cycles,4294967313);
  const wideStats=await wide.device.telemetry();assert.equal(wideStats.snapshotCycles,4294967313);assert.equal(wideStats.phaseCycles[0],4294967313);
  const swapped=fixture({version:5});await swapped.device.status();await swapped.device.telemetry();
  swapped.device.fetcher=fixture({version:4}).device.fetcher;
  assert.equal((await swapped.device.status()).clockHz,50000000);assert.equal(swapped.device.maxDepth,6);
  await assert.rejects(()=>swapped.device.setDepth(8),/Unsupported/);
  swapped.device.fetcher=fixture({version:5}).device.fetcher;await swapped.device.status();await swapped.device.setDepth(8);
  assert.equal(swapped.device.maxDepth,8);
  for(const options of [{version:5,badBound:true},{version:5,badPV:true},{version:5,badClock:true}]) {
    const f=fixture(options);await assert.rejects(()=>f.device.evaluate(f.game));assert(!f.calls.includes(11));
  }
  await assert.rejects(()=>fixture({version:6}).device.status(),/matching/);
  for(const options of [{badLegal:true},{badBoard:true},{badExplanation:true}]) {
    const f=fixture(options);await assert.rejects(()=>f.device.evaluate(f.game));
    assert(!f.calls.includes(11),'A failed independent check must prevent FPGA commit');assert(f.stopped());
  }
  const cancelled=fixture();await assert.rejects(()=>cancelled.device.evaluate(cancelled.game,{cancelled:()=>true}),/Stopped/);
  assert(!cancelled.calls.includes(11));
  const broken=new Fpga(async()=>({ok:false,json:async()=>({error:'No FPGA reply'})}));
  await assert.rejects(()=>broken.status(),/No FPGA reply/);
  console.log('Transport, eight-ply/time controls, version changes, search telemetry, legal-set verification, board readback, commit guards, cancellation and disconnected hardware checks passed.');
})().catch(error=>{console.error(error);process.exitCode=1;});
