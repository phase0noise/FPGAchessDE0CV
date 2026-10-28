/* Local browser integration with an explicitly simulated protocol endpoint.
 * This is a UI test, not physical-board acceptance or an FPGA simulation. */
'use strict';
const http=require('node:http'),fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {spawn}=require('node:child_process');
const {Position,Game,uci}=require('../python/web/chess.js');
const {hex,unhex}=require('../python/web/fpga.js');
const root=path.resolve(__dirname,'../python');
let p=new Position(),done=false,generation=1,selected=0,requestedDepth=5;
let endpointAvailable=true,holdSearch=false,deviceSearching=false;
const searchDepths=[];
function respondCommand(bytes){
  const sub=bytes[0];
  switch(sub){
    case 0:{
      const a=new Uint8Array(40);a.set([83,67,70,50]);a[4]=deviceSearching&&!done?1:0;a[5]=done?1:0;a[7]=p.turn;a[15]=5;a[28]=requestedDepth;a[29]=done?requestedDepth:0;
      new DataView(a.buffer).setUint32(36,55000000);new DataView(a.buffer).setUint32(16,5500000);
      const moves=p.legalMoves();selected=moves.find(m=>uci(m)==='e7e5')??moves[0];
      a[8]=moves.length>>8;a[9]=moves.length&255;a[10]=selected>>8;a[11]=selected&255;
      a[23]=generation;return a;
    }
    case 1:p.board=Uint8Array.from(bytes.slice(1,65));p.turn=bytes[65];p.rights=bytes[66];p.ep=bytes[67];generation++;return [0];
    case 2:deviceSearching=true;done=!holdSearch;searchDepths.push(requestedDepth);return [0];
    case 3:deviceSearching=false;done=false;return [0];
    case 5:return p.positionBytes();
    case 7:{const a=new Uint8Array(64),moves=p.legalMoves();for(let i=0;i<16;i++){const m=moves[bytes[1]*16+i]||0;a[i*4]=m>>8;a[i*4+1]=m&255;}return a;}
    case 11:p.make(selected);deviceSearching=false;return [0];
    case 4:{const a=new Uint8Array(80);for(let s=0;s<64;s++)a[s+16]=(s*5-127)&255;return a;}
    case 12:return new Uint8Array(64);
    case 13:requestedDepth=bytes[12];return [0];
    case 18:{const a=new Uint8Array(128);a[8]=requestedDepth;a[9]=4;a[10]=done?requestedDepth:0;a[11]=2;a[15]=7;
      const view=new DataView(a.buffer),phases=requestedDepth?[50000,1000000,2000000,750000,1500000,100000,100000]:[5500000,0,0,0,0,0,0];
      view.setUint32(0,requestedDepth?200:0);view.setUint32(20,55000000);view.setUint32(98,5500000);
      phases.forEach((cycles,i)=>view.setUint32(36+i*4,cycles));
      a[24]=8;a[25]=8;a[26]=4;a[27]=4;a[93]=15;a[126]=4;
      a[64]=done?1:0;a[65]=selected>>8;a[66]=selected&255;return a;}
    case 19:{const a=new Uint8Array(16),moves=p.legalMoves();for(let i=0;i<16;i++)a[i]=requestedDepth|(moves[bytes[1]*16+i]===selected?0:64);return a;}
    case 14:{const a=new Uint8Array(72),moves=p.legalMoves();for(let i=0;i<4;i++){const m=moves[bytes[1]*4+i]||0;a[i*18]=m>>8;a[i*18+1]=m&255;}return a;}
    default:return [0];
  }
}
const server=http.createServer((req,res)=>{
  if(req.url==='/api/command'){
    if(!endpointAvailable){res.writeHead(504,{'Content-Type':'application/json'});res.end(JSON.stringify({error:'Simulated disconnected FPGA'}));req.resume();return;}
    let body='';req.on('data',a=>body+=a);req.on('end',()=>{try{const payload=respondCommand(unhex(body));res.writeHead(200,{'Content-Type':'application/json'});res.end(JSON.stringify({status:0,payload:hex(payload)}));}catch(e){res.writeHead(500);res.end(JSON.stringify({error:e.message}));}});return;
  }
  const name=req.url==='/'?'index.html':req.url.slice(1),file=path.join(root,'web',name);
  if(!['index.html','style.css','chess.js','fpga.js','app.js','pieces.png'].includes(name)){res.writeHead(404);res.end();return;}
  res.setHeader('Content-Type',name.endsWith('.js')?'application/javascript':name.endsWith('.css')?'text/css':name.endsWith('.png')?'image/png':'text/html');
  fs.createReadStream(file).pipe(res);
});
function delay(ms){return new Promise(resolve=>setTimeout(resolve,ms));}
function findChrome(){
  if(process.env.CHROME)return process.env.CHROME;
  const names=process.platform==='win32'?['chrome.exe','chromium.exe']:['google-chrome','google-chrome-stable','chromium','chromium-browser'];
  const candidates=(process.env.PATH||'').split(path.delimiter).filter(Boolean).flatMap(dir=>names.map(name=>path.join(dir,name)));
  if(process.platform==='win32'){
    for(const dir of [process.env.PROGRAMFILES,process.env['PROGRAMFILES(X86)'],process.env.LOCALAPPDATA].filter(Boolean))
      candidates.push(path.join(dir,'Google','Chrome','Application','chrome.exe'));
  }else if(process.platform==='darwin'){
    candidates.push('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome');
  }
  const executable=candidates.find(candidate=>fs.existsSync(candidate));
  assert(executable,'Chrome/Chromium not found. Add it to PATH or set CHROME.');
  return executable;
}
async function run(){
  console.log('Starting browser smoke test with a simulated FPGA endpoint.');
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const port=server.address().port,debugPort=port+1;
  const chrome=findChrome();
  const browser=spawn(chrome,['--headless=new','--no-first-run','--no-default-browser-check','--disable-crash-reporter',`--remote-debugging-port=${debugPort}`,`--user-data-dir=${path.join(root,`.cache/browser-profile-${process.pid}`)}`,'about:blank'],{windowsHide:true,stdio:'ignore'});
  let socket;
  try {
    let pages;
    for(let i=0;i<60;i++){try{pages=await(await fetch(`http://127.0.0.1:${debugPort}/json`,{signal:AbortSignal.timeout(300)})).json();if(pages.some(p=>p.type==='page'))break;}catch(_){}await delay(100);}
    assert(pages,'Chrome did not expose its debugging endpoint');
    socket=new WebSocket(pages.find(p=>p.type==='page').webSocketDebuggerUrl);
    await new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('Browser WebSocket open timed out')),5000);socket.onopen=()=>{clearTimeout(timer);resolve();};socket.onerror=reject;});
    let id=0;const pending=new Map(),errors=[];
    socket.onmessage=event=>{const msg=JSON.parse(event.data);if(msg.id){const task=pending.get(msg.id);pending.delete(msg.id);msg.error?task.reject(Error(JSON.stringify(msg.error))):task.resolve(msg.result);}else if(msg.method==='Runtime.exceptionThrown')errors.push(msg.params);};
    const call=(method,params={})=>new Promise((resolve,reject)=>{const n=++id;const timer=setTimeout(()=>{pending.delete(n);reject(Error(`Browser command timed out: ${method}`));},5000);pending.set(n,{resolve:value=>{clearTimeout(timer);resolve(value);},reject});socket.send(JSON.stringify({id:n,method,params}));});
    const evaluate=async expression=>{const r=await call('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});if(r.exceptionDetails)throw Error(JSON.stringify(r.exceptionDetails));return r.result.value;};
    async function wait(expression){for(let i=0;i<100;i++){if(await evaluate(expression))return;await delay(60);}throw Error(`Browser wait timed out: ${expression}`);}
    async function restoreGame(saved) {
      // Install after the previous page's pagehide save, before app startup.
      const script=await call('Page.addScriptToEvaluateOnNewDocument',{source:`localStorage.setItem('fpga-chess-game',${JSON.stringify(JSON.stringify(saved))})`});
      try {await call('Page.reload');await wait('document.querySelector("#connection.online")');}
      finally {await call('Page.removeScriptToEvaluateOnNewDocument',{identifier:script.identifier});}
    }
    const center=s=>evaluate(`(()=>{const r=document.querySelector('[data-square="${s}"]').getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2};})()`);
    async function dragPiece(from,to,{touch=false,cancel=false}={}) {
      const start=typeof from==='number'?await center(from):from,end=typeof to==='number'?await center(to):to;
      if(touch) await call('Input.dispatchTouchEvent',{type:'touchStart',touchPoints:[{...start,id:0}]});
      else {
        await call('Input.dispatchMouseEvent',{type:'mouseMoved',...start});
        await call('Input.dispatchMouseEvent',{type:'mousePressed',...start,button:'left',buttons:1,clickCount:1});
      }
      for(let step=1;step<=8;step++) {
        const point={x:start.x+(end.x-start.x)*step/8,y:start.y+(end.y-start.y)*step/8};
        if(touch) await call('Input.dispatchTouchEvent',{type:'touchMove',touchPoints:[{...point,id:0}]});
        else await call('Input.dispatchMouseEvent',{type:'mouseMoved',...point,button:'left',buttons:1});
        await delay(18);
      }
      if(touch) await call('Input.dispatchTouchEvent',{type:cancel?'touchCancel':'touchEnd',touchPoints:[]});
      else await call('Input.dispatchMouseEvent',{type:'mouseReleased',...end,button:'left',buttons:0,clickCount:1});
      await delay(80);
    }
    const waitForReply=()=>wait('document.querySelectorAll(".move-row").length===1 && document.querySelector(".move-row").textContent.includes("e5") && !document.querySelector("#new-game").disabled');
    await call('Runtime.enable');await call('Page.enable');
    await call('Emulation.setDeviceMetricsOverride',{width:1200,height:950,deviceScaleFactor:1,mobile:false});
    await call('Page.navigate',{url:`http://127.0.0.1:${port}/`});
    await wait('document.querySelector("#connection.online")');
    console.log('Browser connected to the simulated endpoint.');
    assert.equal(await evaluate('document.querySelectorAll(".square").length'),64);
    assert.equal(await evaluate('document.querySelectorAll(".piece").length'),32);
    assert.equal(await evaluate('document.querySelector("#depth").value'),'5');
    assert.equal(await evaluate('document.querySelector("#time").value'),'10');
    assert.equal(await evaluate('document.documentElement.dataset.theme'),'dark');
    assert.equal(await evaluate('getComputedStyle(document.documentElement).colorScheme'),'dark');
    await evaluate('document.querySelector("#theme").click()');
    assert.equal(await evaluate('document.documentElement.dataset.theme'),'light');
    await call('Page.reload');await wait('document.querySelector("#connection.online")');
    assert.equal(await evaluate('document.documentElement.dataset.theme'),'light','Theme preference was not restored');
    await evaluate('document.querySelector("#theme").click()');
    assert.equal(await evaluate('document.querySelector(\'meta[name="theme-color"]\').content'),'#111c18');
    await evaluate('document.querySelector(\'[data-square="12"]\').click()');
    assert.equal(await evaluate('document.querySelectorAll(".legal").length'),2);
    await evaluate('document.querySelector(\'[data-square="28"]\').click()');
    await waitForReply();
    assert.equal(await evaluate('document.querySelector("#turn-label").textContent'),'Your move');
    assert.equal(await evaluate('document.querySelector("#search-depth").textContent'),'5 ply');
    assert.equal(await evaluate('document.querySelector("#cache-hits").textContent'),'7');
    assert.equal(await evaluate('document.querySelectorAll(".candidate-row").length'),5);
    assert.equal(await evaluate('document.querySelectorAll(".field-cell").length'),64);
    assert.equal(await evaluate('document.querySelectorAll(".score-parts>div").length'),7);
    assert.equal(await evaluate('document.querySelector("#legal-count").textContent'),'20');
    assert.equal(await evaluate('document.querySelector("#engine-clock").textContent'),'55.0 MHz / 4 lanes');
    assert.equal(await evaluate('document.querySelector("#decision").textContent'),'0.10 s');
    assert(await evaluate('[...document.querySelectorAll("#phase-bar span")].every(s=>s.getBoundingClientRect().width>0)'));
    assert.equal(await evaluate('document.querySelectorAll("#phase-legend>span").length'),7);
    assert(await evaluate('document.querySelector("#pv-line").textContent.includes("Captured continuation")'));
    assert(await evaluate('[...document.querySelectorAll(".candidate-row strong")].some(e=>e.textContent.startsWith("≤"))'));
    fs.writeFileSync(path.join(root,'.cache/browser-desktop.png'),Buffer.from((await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:true})).data,'base64'));
    await evaluate('document.querySelector("#undo").click()');assert.equal(await evaluate('document.querySelectorAll(".move-row").length'),0);
    await dragPiece(12,36); // e2-e5 is illegal.
    assert.equal(await evaluate('document.querySelectorAll(".move-row").length'),0);
    assert(await evaluate('document.querySelector(\'[data-square="12"] .piece\')'));
    await dragPiece(12,{x:1180,y:200}); // Dropping outside the board cancels.
    assert.equal(await evaluate('document.querySelectorAll(".move-row").length'),0);
    assert.equal(await evaluate('document.querySelectorAll(".drag-piece,.drag-origin,.drop-target").length'),0);
    await dragPiece(12,28);await waitForReply();
    assert(await evaluate('document.querySelector(\'[data-square="28"] .piece\')'),'Mouse drag did not move the pawn');
    await evaluate('document.querySelector("#undo").click()');
    await evaluate('document.querySelector("#flip").click()');assert.equal(await evaluate('document.querySelector(".square").dataset.square'),'7');
    await call('Emulation.setDeviceMetricsOverride',{width:390,height:844,deviceScaleFactor:1,mobile:true});
    await call('Emulation.setTouchEmulationEnabled',{enabled:true,maxTouchPoints:1});
    await delay(150);
    assert(await evaluate('document.documentElement.scrollWidth<=window.innerWidth'),'Mobile layout overflowed');
    const scrollBefore=await evaluate('window.scrollY'),empty=await center(27);
    await dragPiece(empty,{x:empty.x,y:empty.y-110},{touch:true});
    assert.equal(await evaluate('window.scrollY'),scrollBefore,'Touching an empty square scrolled the page');
    await dragPiece(12,28,{touch:true});await waitForReply();
    assert.equal(await evaluate('window.scrollY'),scrollBefore,'Dragging a piece scrolled the page');
    assert(await evaluate('document.querySelector(\'[data-square="28"] .piece\')'),'Touch drag on a flipped board failed');
    await evaluate('document.querySelector("#undo").click()');
    await dragPiece(12,28,{touch:true,cancel:true});
    assert.equal(await evaluate('document.querySelectorAll(".move-row").length'),0,'A cancelled gesture played a move');
    assert.equal(await evaluate('document.querySelectorAll(".drag-piece,.drag-origin,.drop-target").length'),0);
    await evaluate('document.querySelector(\'[data-square="27"]\').click()');
    await dragPiece(12,12,{touch:true});
    assert.equal(await evaluate('document.querySelectorAll(".legal").length'),2,'A touch tap did not select the pawn');
    await dragPiece(28,28,{touch:true});await waitForReply();
    assert.equal(await evaluate('window.scrollY'),scrollBefore,'Tap-to-move scrolled the page');
    await dragPiece({x:8,y:700},{x:8,y:300},{touch:true});await delay(300);
    assert(await evaluate('window.scrollY>30'),'Scrolling outside the board was blocked');
    await evaluate('window.scrollTo(0,0)');await delay(150);
    fs.writeFileSync(path.join(root,'.cache/browser-mobile.png'),Buffer.from((await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:true})).data,'base64'));
    const promotionGame=new Game();
    for(const text of ['a2a4','h7h5','a4a5','h5h4','a5a6','h4h3','a6b7','h3g2']) {
      const move=promotionGame.position.legalMoves().find(move=>uci(move)===text);assert.notEqual(move,undefined);promotionGame.push(move);
    }
    await restoreGame({moves:promotionGame.history.map(h=>h.move),human:0,depth:3,claimed:false});
    await dragPiece(49,56,{touch:true});await wait('document.querySelector("#promotion").open');
    await evaluate('document.querySelector("#promotion-cancel").click()');
    assert(await evaluate('document.querySelector(\'[data-square="49"] .piece\')'),'Cancelling promotion removed the pawn');
    await dragPiece(49,56,{touch:true});await wait('document.querySelector("#promotion").open');
    await evaluate('document.querySelector(\'#promotion-options [aria-label="queen"]\').click()');
    await wait('!document.querySelector("#new-game").disabled && document.querySelectorAll(".move-row").length===5');
    assert.equal(await evaluate('document.querySelector(\'[data-square="56"]\').getAttribute("aria-label")'),'a8 white queen');
    // Saved history survives reload; disconnection is an error, never a software opponent.
    await call('Page.reload');await wait('document.querySelector("#connection.online")');
    assert.equal(await evaluate('document.querySelectorAll(".square").length'),64);
    assert.equal(await evaluate('document.querySelector(\'[data-square="56"]\').getAttribute("aria-label")'),'a8 white queen');
    assert.equal(await evaluate('document.documentElement.dataset.theme'),'dark');
    assert.equal(await evaluate('document.querySelector("#white-points").textContent'),'6 pts');
    // Pass-and-play supports both colors and works with a disconnected FPGA.
    endpointAvailable=false;
    await evaluate('document.querySelector("#mode").value="local";document.querySelector("#mode").dispatchEvent(new Event("change"));document.querySelector("#new-game").click();document.querySelector("#connect").click()');
    await wait('document.querySelector("#connection.offline") && !document.querySelector("#new-game").disabled');
    const searchesBeforeLocal=searchDepths.length;
    for(const [from,to] of [[12,28],[51,35],[28,35]]) await evaluate(`document.querySelector('[data-square="${from}"]').click();document.querySelector('[data-square="${to}"]').click()`);
    assert.equal(await evaluate('JSON.parse(localStorage.getItem("fpga-chess-game")).moves.length'),3);
    assert.equal(await evaluate('document.querySelector("#white-points").textContent'),'1 pts');
    assert.equal(await evaluate('document.querySelector("#material-balance").textContent'),'White +1 material');
    assert.equal(searchDepths.length,searchesBeforeLocal,'Pass-and-play requested an FPGA search');
    await evaluate('document.querySelector("#undo").click()');
    assert.equal(await evaluate('JSON.parse(localStorage.getItem("fpga-chess-game")).moves.length'),2);
    assert.equal(await evaluate('document.querySelector("#white-points").textContent'),'0 pts');
    // Self-play alternates both sides, pauses between turns, and restores paused.
    endpointAvailable=true;
    await evaluate('document.querySelector("#connect").click()');await wait('document.querySelector("#connection.online") && !document.querySelector("#new-game").disabled');
    await evaluate('document.querySelector("#mode").value="watch";document.querySelector("#mode").dispatchEvent(new Event("change"));document.querySelector("#new-game").click()');
    await wait('JSON.parse(localStorage.getItem("fpga-chess-game")).moves.length>=2 && !document.querySelector("#new-game").disabled');
    await evaluate('document.querySelector("#stop").click()');
    const pausedMoves=await evaluate('JSON.parse(localStorage.getItem("fpga-chess-game")).moves.length');
    await delay(900);assert.equal(await evaluate('JSON.parse(localStorage.getItem("fpga-chess-game")).moves.length'),pausedMoves);
    await call('Page.reload');await wait('document.querySelector("#connection.online")');
    assert.equal(await evaluate('document.querySelector("#turn-label").textContent'),'Paused');
    await evaluate('document.querySelector("#undo").click()');
    assert.equal(await evaluate('JSON.parse(localStorage.getItem("fpga-chess-game")).moves.length'),pausedMoves-1);
    // An in-flight self-play search can be stopped without committing a move.
    holdSearch=true;
    await evaluate('document.querySelector("#new-game").click()');
    await wait('document.querySelector("#new-game").disabled && !document.querySelector("#stop").hidden');
    await evaluate('document.querySelector("#stop").click()');
    await wait('!document.querySelector("#new-game").disabled');holdSearch=false;
    assert.equal(await evaluate('JSON.parse(localStorage.getItem("fpga-chess-game")).moves.length'),0);
    // Undo after stopping a normal opponent search must allow a fresh reply.
    holdSearch=true;
    await evaluate('document.querySelector("#mode").value="human";document.querySelector("#new-game").click();document.querySelector(\'[data-square="12"]\').click();document.querySelector(\'[data-square="28"]\').click()');
    await wait('document.querySelector("#new-game").disabled');
    await evaluate('document.querySelector("#stop").click()');await wait('!document.querySelector("#new-game").disabled');
    holdSearch=false;
    await evaluate('document.querySelector("#undo").click();document.querySelector(\'[data-square="12"]\').click();document.querySelector(\'[data-square="28"]\').click()');
    await waitForReply();
    // Restore a nearly expired human clock, then check Spatial followed by the normal reply depth.
    await restoreGame({moves:[],human:0,mode:'speed',roundSeconds:5,clockLeft:80,clockMove:0,depth:3,timeSeconds:3});
    const speedStart=searchDepths.length;
    assert.equal(await evaluate('document.querySelector("#clock-time").textContent'),'Paused');
    await evaluate('document.querySelector("#resume").click()');
    await wait('JSON.parse(localStorage.getItem("fpga-chess-game")).moves.length===2 && !document.querySelector("#new-game").disabled');
    assert.deepEqual(searchDepths.slice(speedStart),[0,3],'Timeout must use Spatial, then restore the opponent search depth');
    assert.deepEqual(await evaluate('JSON.parse(localStorage.getItem("fpga-chess-game")).assisted'),[0]);
    assert(await evaluate('document.querySelector(".move-row").textContent.includes("⚡")'));
    await evaluate('document.querySelector("#stop").click()');
    const remaining=await evaluate('document.querySelector("#clock-progress").value');
    await delay(250);assert.equal(await evaluate('document.querySelector("#clock-progress").value'),remaining,'Paused clock kept running');
    // A promotion dialog cannot outlive its speed deadline or submit a stale move.
    await restoreGame({moves:promotionGame.history.map(h=>h.move),human:0,mode:'speed',roundSeconds:5,clockLeft:1200,clockMove:8,depth:3,timeSeconds:3});
    await evaluate('document.querySelector("#resume").click();document.querySelector(\'[data-square="49"]\').click();document.querySelector(\'[data-square="56"]\').click()');
    await wait('document.querySelector("#promotion").open');
    await wait('!document.querySelector("#promotion").open && JSON.parse(localStorage.getItem("fpga-chess-game")).moves.length===10 && !document.querySelector("#new-game").disabled');
    assert.deepEqual(await evaluate('JSON.parse(localStorage.getItem("fpga-chess-game")).assisted'),[8]);
    await evaluate('document.querySelector("#stop").click()');
    fs.writeFileSync(path.join(root,'.cache/browser-console-mobile.png'),Buffer.from((await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:true})).data,'base64'));
    assert.deepEqual(errors,[],'Browser raised JavaScript exceptions');
    console.log('Desktop/mobile browser: gestures, themes, promotions, captures, engine console, offline pass-and-play, self-play, stop/resume, persistence and Spatial speed-round timeout passed.');
  }finally{if(socket)socket.close();browser.kill();server.close();}
}
run().catch(error=>{console.error(error);server.close();process.exitCode=1;});
