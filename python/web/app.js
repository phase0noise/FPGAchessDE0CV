(function(){
  'use strict';
  const {Game,decode,square,uci,PIECE_VALUES}=ChessRules;
  const $=id=>document.getElementById(id),game=new Game(),fpga=new FpgaChess.Fpga();
  let human=0,flipped=false,selected=null,legal=[],busy=false,connected=false,cancel=false,claimed=false;
  let drag=null,suppressClick=false;
  let mode='human',roundSeconds=10,paused=false,searching=false,autoTimer=null,clockDeadline=0,clockLeft=null,promotionFinish=null;
  let trace=[],assisted=[],engineClockHz=50000000;
  const modeHelp={human:'Make your move. The FPGA finds its reply.',watch:'One FPGA plays both colors. Pause whenever you like.',local:'Two players, one board. Pass the phone after each move.',speed:'Beat the countdown, or the FPGA plays a Spatial move for you.'};
  const names=['','pawn','knight','bishop','rook','queen','king'];
  function applyTheme(theme) {
    const dark=theme!=='light';
    document.documentElement.dataset.theme=dark?'dark':'light';
    document.querySelector('meta[name="theme-color"]').content=dark?'#111c18':'#f6f4ed';
    $('theme').textContent=dark?'Light mode':'Dark mode';
    $('theme').setAttribute('aria-label',`Switch to ${dark?'light':'dark'} theme`);
    try {localStorage.setItem('fpga-chess-theme',dark?'dark':'light');} catch(_) {}
  }
  function save() {
    try{localStorage.setItem('fpga-chess-game',JSON.stringify({moves:game.history.map(h=>h.move),human,mode,roundSeconds,assisted,
      clockLeft:clockDeadline?Math.max(0,clockDeadline-Date.now()):clockLeft,clockMove:game.history.length,
      depth:Number($('depth').value),timeSeconds:Number($('time').value),claimed}));}catch(_){}
  }
  function restore() {
    try {
      const saved=JSON.parse(localStorage.getItem('fpga-chess-game'));
      if(saved&&Array.isArray(saved.moves)&&saved.moves.length<2000) {
        for(const move of saved.moves) game.push(move);
        human=saved.human===1?1:0;claimed=!!saved.claimed&&game.canClaim();
        if(Object.hasOwn(modeHelp,saved.mode)) mode=saved.mode;
        if([5,10,15,30].includes(saved.roundSeconds)) roundSeconds=saved.roundSeconds;
        if(Array.isArray(saved.assisted)) assisted=saved.assisted.filter(i=>Number.isInteger(i)&&i>=0&&i<game.history.length);
        if(mode==='speed'&&saved.clockMove===game.history.length&&Number.isFinite(saved.clockLeft)) clockLeft=Math.max(0,Math.min(roundSeconds*1000,saved.clockLeft));
        if([0,2,3,4,5,6,7,8].includes(saved.depth)) $('depth').value=saved.depth;
        if([3,10,20,30].includes(saved.timeSeconds)) $('time').value=saved.timeSeconds;
      }
    } catch(_) {game.reset();assisted=[];clockLeft=null;}
    paused=mode==='watch'||mode==='speed';
    $('side').value=human;$('mode').value=mode;$('round-seconds').value=roundSeconds;flipped=!!human;settingsHelp();
  }
  function settingsHelp() {
    const choice=$('mode').value;
    $('mode-help').textContent=modeHelp[choice];
    $('side-setting').hidden=choice==='watch'||choice==='local';
    $('round-setting').hidden=choice!=='speed';
    $('depth').closest('label').hidden=choice==='local';$('time').closest('label').hidden=choice==='local';
  }
  const colorName=side=>side?'Black':'White';
  const isHumanTurn=()=>mode==='local'||(mode!=='watch'&&game.position.turn===human);
  function resetClock() {clockDeadline=0;clockLeft=null;}
  function paintClock() {
    $('round-clock').hidden=mode!=='speed';
    if(mode!=='speed') return;
    const remaining=clockDeadline?Math.max(0,clockDeadline-Date.now()):(clockLeft??roundSeconds*1000);
    $('clock-time').textContent=paused?'Paused':isHumanTurn()?`${Math.ceil(remaining/1000)} s`:'FPGA turn';
    $('clock-caption').textContent=paused?'RESUME WHEN YOU ARE READY':isHumanTurn()?'YOUR MOVE · SPATIAL TAKES OVER AT ZERO':'YOUR CLOCK STARTS AFTER THE FPGA REPLIES';
    $('clock-progress').max=roundSeconds;$('clock-progress').value=remaining/1000;
    $('round-clock').classList.toggle('urgent',isHumanTurn()&&!paused&&remaining<=3000);
  }
  function renderCaptures() {
    const taken=game.captures();
    for(const side of [0,1]) {
      const tray=$(side?'black-captures':'white-captures');tray.replaceChildren();
      for(const kind of [5,4,3,2,1]) {
        const pieces=taken[side].pieces.filter(p=>(p&7)===kind);
        if(!pieces.length) continue;
        const item=document.createElement('span');item.className='captured-group';
        item.title=`${pieces.length} ${names[kind]}${pieces.length>1?'s':''} · ${pieces.length*PIECE_VALUES[kind]} points`;
        item.setAttribute('aria-label',item.title);
        item.append(pieceElement(pieces[0]));const count=document.createElement('small');
        count.textContent=`${pieces.length>1?'×'+pieces.length+' · ':''}${PIECE_VALUES[kind]}`;item.append(count);tray.append(item);
      }
      if(!tray.children.length) {const empty=document.createElement('span');empty.className='no-captures';empty.textContent='None yet';tray.append(empty);}
      $(side?'black-points':'white-points').textContent=`${taken[side].points} pts`;
    }
    let balance=0;for(const p of game.position.board) balance+=(p&8?-1:1)*PIECE_VALUES[p&7];
    $('material-balance').textContent=balance?`${balance>0?'White':'Black'} +${Math.abs(balance)} material`:'Material equal';
  }
  function pieceElement(p) {
    const span=document.createElement('span');span.className='piece';
    span.style.backgroundPosition=`${((p&7)-1)*20}% ${(p&8)?100:0}%`;
    return span;
  }
  function render() {
    const p=game.position,outcome=claimed?{text:'Draw claimed',result:'1/2-1/2'}:game.outcome();
    legal=p.legalMoves();
    const last=game.history.length?decode(game.history.at(-1).move):null;
    const destinations=new Set(selected===null?[]:legal.filter(m=>decode(m).from===selected).map(m=>decode(m).to));
    const board=$('board');board.replaceChildren();
    for(let row=0;row<8;row++) for(let col=0;col<8;col++) {
      const x=flipped?7-col:col,y=flipped?row:7-row,s=y*8+x,piece=p.board[s];
      const button=document.createElement('button');button.className='square'+((x+y)%2===0?' dark':'');button.dataset.square=s;
      button.setAttribute('role','gridcell');button.setAttribute('aria-label',`${square(s)}${piece?' '+((piece&8)?'black ':'white ')+names[piece&7]:''}`);
      if(piece) button.append(pieceElement(piece));
      if(last&&(s===last.from||s===last.to)) button.classList.add('last');
      if(s===selected) button.classList.add('selected');
      if(destinations.has(s)) button.classList.add('legal');
      if((piece&7)===6&&(piece>>3)===p.turn&&p.inCheck()) button.classList.add('check');
      if(col===0) {const c=document.createElement('span');c.className='coord rank';c.textContent=String(y+1);button.append(c);}
      if(row===7) {const c=document.createElement('span');c.className='coord file';c.textContent='abcdefgh'[x];button.append(c);}
      button.onclick=()=>clickSquare(s);board.append(button);
    }
    $('opponent-name').textContent=mode==='local'?'Black':mode==='watch'?'FPGA · Black':'The FPGA';
    $('opponent-caption').textContent=mode==='local'?'Pass & play':mode==='watch'?'Same engine, both sides':'Spatial intuition + search';
    $('player-name').textContent=mode==='local'?'White':mode==='watch'?'FPGA · White':'You';
    $('human-caption').textContent=mode==='watch'?'Self play':mode==='local'?'Pass & play':`Playing ${human?'black':'white'}`;
    $('engine-color').textContent=mode==='local'?'2 PLAYERS':mode==='watch'?'SELF PLAY':human?'WHITE':'BLACK';
    $('turn-label').textContent=outcome?'Game finished':busy?'Thinking…':paused?'Paused':mode==='local'?`${colorName(p.turn)} to move`:mode==='watch'?`${colorName(p.turn)} · FPGA`:p.turn===human?'Your move':'FPGA to move';
    if(!busy) $('status').textContent=outcome?outcome.text:paused?'Game paused.':mode==='local'?`${colorName(p.turn)} to move${p.inCheck()?' · check':''}.`:!connected?'Connect to your FPGA':isHumanTurn()?(p.inCheck()?'Your king is in check.':'Your move.'):`${colorName(p.turn)} · FPGA to move.`;
    for(const id of ['new-game','mode','side','round-seconds','depth','time','connect']) $(id).disabled=busy;
    $('undo').disabled=busy||!game.history.length;
    $('undo').textContent=mode==='watch'||mode==='local'?'Undo move':'Undo turn';
    $('resume').hidden=busy||!!outcome||mode==='local'||(!paused&&isHumanTurn());
    $('resume').textContent=paused?'Resume game':'Play FPGA turn';
    $('resume').disabled=!connected;
    $('stop').hidden=!!outcome||(!searching&&!((mode==='watch'||mode==='speed')&&!paused));
    $('stop').textContent=searching?'Stop search':'Pause game';
    $('claim').hidden=busy||!!outcome||!isHumanTurn()||!game.canClaim();
    renderCaptures();paintClock();
    const moves=$('moves');moves.replaceChildren();
    if(!game.history.length) {const empty=document.createElement('p');empty.className='empty-moves';empty.textContent=mode==='watch'?'A circuit on both sides of the board.':'The first move is yours.';moves.append(empty);}
    for(let i=0;i<game.history.length;i+=2) {
      const row=document.createElement('div');row.className='move-row';
      for(const [j,text] of [`${i/2+1}.`,game.history[i].san,game.history[i+1]?.san||''].entries()) {const span=document.createElement('span');span.textContent=text;if(j===0)span.className='move-number';else if(assisted.includes(i+j-1)){span.textContent+=' ⚡';span.title='Spatial move played when the timer expired';}row.append(span);}
      moves.append(row);
    }
    moves.scrollTop=moves.scrollHeight;
  }
  function canMove() {return !busy&&(connected||mode==='local')&&isHumanTurn()&&!(mode==='speed'&&paused)&&!game.outcome()&&!claimed;}
  function squareAt(x,y) {
    const element=document.elementFromPoint(x,y)?.closest('.square');
    return element&&$('board').contains(element)?element:null;
  }
  function clearDrag() {
    const previous=drag;drag=null;
    if(!previous) return null;
    previous.ghost?.remove();
    $('board').classList.remove('dragging');
    $('board').querySelectorAll('.drag-origin,.drop-target').forEach(element=>element.classList.remove('drag-origin','drop-target'));
    if($('board').hasPointerCapture(previous.id)) $('board').releasePointerCapture(previous.id);
    return previous;
  }
  function cancelDrag() {if(clearDrag()?.moving) render();}
  const board=$('board');
  board.addEventListener('pointerdown',event=>{
    if(!event.isPrimary||event.button!==0||!canMove()||drag) return;
    const element=event.target.closest('.square');
    if(!element||!board.contains(element)) return;
    const from=Number(element.dataset.square),piece=game.position.board[from];
    if(!piece||(piece>>3)!==game.position.turn) return;
    drag={id:event.pointerId,from,piece,position:game.position,x:event.clientX,y:event.clientY,moving:false,ghost:null};
  });
  window.addEventListener('pointermove',event=>{
    if(!drag||event.pointerId!==drag.id) return;
    if(!canMove()||game.position!==drag.position) {cancelDrag();return;}
    if(!drag.moving) {
      if(Math.hypot(event.clientX-drag.x,event.clientY-drag.y)<7) return;
      selected=drag.from;render();drag.moving=true;
      const origin=board.querySelector(`[data-square="${drag.from}"]`);
      origin.classList.add('drag-origin');
      drag.size=origin.getBoundingClientRect().width;
      drag.ghost=pieceElement(drag.piece);drag.ghost.classList.add('drag-piece');
      drag.ghost.style.width=drag.ghost.style.height=`${drag.size}px`;
      document.body.append(drag.ghost);board.classList.add('dragging');
      board.setPointerCapture(event.pointerId);
    }
    event.preventDefault();
    drag.ghost.style.transform=`translate3d(${event.clientX-drag.size/2}px,${event.clientY-drag.size/2}px,0)`;
    board.querySelector('.drop-target')?.classList.remove('drop-target');
    const target=squareAt(event.clientX,event.clientY);
    if(target&&legal.some(move=>{const d=decode(move);return d.from===drag.from&&d.to===Number(target.dataset.square);})) target.classList.add('drop-target');
  },{passive:false});
  window.addEventListener('pointerup',event=>{
    if(!drag||event.pointerId!==drag.id) return;
    const target=squareAt(event.clientX,event.clientY),previous=clearDrag();
    if(!previous.moving) return;
    event.preventDefault();suppressClick=true;setTimeout(()=>{suppressClick=false;},0);
    selected=previous.from;
    const to=target?Number(target.dataset.square):null;
    if(to!==null&&legal.some(move=>{const d=decode(move);return d.from===selected&&d.to===to;})) clickSquare(to);
    else render();
  });
  window.addEventListener('pointercancel',event=>{if(drag?.id===event.pointerId) cancelDrag();});
  board.addEventListener('lostpointercapture',event=>{if(drag?.id===event.pointerId) cancelDrag();});
  window.addEventListener('blur',cancelDrag);
  document.addEventListener('visibilitychange',()=>{if(document.hidden) cancelDrag();});
  board.addEventListener('click',event=>{if(suppressClick){event.preventDefault();event.stopImmediatePropagation();suppressClick=false;}},{capture:true});
  board.addEventListener('contextmenu',event=>event.preventDefault());
  board.addEventListener('dragstart',event=>event.preventDefault());
  board.addEventListener('wheel',event=>event.preventDefault(),{passive:false});
  function message(text,error=false) {$('message').textContent=text;$('message').classList.toggle('error',error);}
  function connection(on) {
    connected=on;const element=$('connection');element.className='connection '+(on?'online':'offline');
    element.replaceChildren(document.createElement('i'),document.createTextNode(on?'FPGA connected':'FPGA disconnected'));
  }
  async function connect() {
    if(busy) return;busy=true;render();$('status').textContent='Connecting…';
    try {
      await fpga.status();await fpga.command(3);connection(true);
      message(paused?'Connected. Resume your game when ready.':'Connected. Ready when you are.');
    } catch(error) {connection(false);message(error.message,true);}
    finally {busy=false;render();scheduleTurn();}
  }
  function setStage(stage,label) {
    const stages=['upload','field','search','verify','commit'],current=stages.indexOf(stage);
    for(const [i,element] of [...$('engine-pipeline').children].entries()) {
      element.classList.toggle('active',i===current);element.classList.toggle('complete',stage==='complete'||i<current);
    }
    $('engine-console').classList.toggle('working',current>=0);
    $('engine-state').textContent=label||({upload:'Loading position',field:'Spatial field',search:'Searching',verify:'Checking result',commit:'Playing move',complete:'Move complete',idle:'Idle',stopped:'Search stopped',error:'Link interrupted'}[stage]);
  }
  function updateMetrics(data) {
    engineClockHz=data.clockHz||engineClockHz;
    const seconds=data.cycles/engineClockHz;
    $('decision').textContent=`${seconds.toFixed(2)} s`;
    if(data.nodes!==undefined) {
      $('nodes').textContent=data.nodes.toLocaleString();$('cutoffs').textContent=data.cutoffs.toLocaleString();
      $('cache-hits').textContent=data.cacheHits.toLocaleString();$('cache-stores').textContent=data.cacheStores.toLocaleString();
      $('node-rate').textContent=seconds>0?Math.round(data.nodes/seconds).toLocaleString():'—';
      $('quiescence').textContent=`${data.quiescence} capture extension plies`;
    }
    if(data.evalLanes) {
      $('engine-clock').textContent=`${(engineClockHz/1e6).toFixed(1)} MHz / ${data.evalLanes} lanes`;
      $('tactical-depth').textContent=data.tacticalDepth;
      $('cache-cutoffs').textContent=`${data.cacheCutoffs.toLocaleString()} / ${data.rootResearches.toLocaleString()}`;
      $('see-calls').textContent=data.seeCalls.toLocaleString();
    }
    if(data.phaseCycles) {
      const labels=['Root / field','Evaluation','Move generation','Move ordering','Board restore','Cache / return','Control'];
      const total=data.phaseCycles.reduce((a,b)=>a+b,0)||1,bar=$('phase-bar'),legend=$('phase-legend');
      bar.replaceChildren();legend.replaceChildren();$('phase-profile').hidden=false;
      data.phaseCycles.forEach((cycles,i)=>{
        const detail=`${labels[i]} · ${(cycles/engineClockHz*1000).toFixed(1)} ms · ${(cycles/total*100).toFixed(1)}%`;
        const segment=document.createElement('span');segment.style.flexGrow=cycles;segment.style.backgroundColor=`hsl(${135+i*32} 38% 50%)`;segment.title=detail;bar.append(segment);
        const item=document.createElement('span');item.textContent=detail;legend.append(item);
      });
      bar.setAttribute('aria-label',labels.map((label,i)=>`${label} ${(data.phaseCycles[i]/total*100).toFixed(1)} percent`).join(', '));
    }
    $('legal-count').textContent=data.count?.toLocaleString()??'—';
    $('search-depth').textContent=data.targetDepth===0?'Spatial':data.depth?`${data.depth}${data.depth!==data.targetDepth?' / '+data.targetDepth:''} ply`:`0 / ${data.targetDepth} ply`;
    $('search-detail').textContent=data.targetDepth===0?'Spatial · no search tree':`Target ${data.targetDepth} ply${data.budgetExpired?' · budget reached':''}`;
  }
  function recordTrace(cycles,nodes) {
    if(!cycles||nodes===undefined) return;
    if(trace.length&&cycles<=trace.at(-1).cycles) return;
    trace.push({cycles,nodes});if(trace.length>120) trace.splice(1,1);
    const maxCycles=trace.at(-1).cycles,maxNodes=Math.max(1,...trace.map(s=>s.nodes));
    $('trace-line').setAttribute('points','0,89 '+trace.map(s=>`${(s.cycles/maxCycles*400).toFixed(1)},${(89-s.nodes/maxNodes*84).toFixed(1)}`).join(' '));
    $('trace-caption').textContent=`${trace.length} SPI sample${trace.length===1?'':'s'} · ${(maxCycles/engineClockHz).toFixed(2)} FPGA seconds · ${nodes.toLocaleString()} nodes`;
  }
  function showField(field,attacks) {
    const board=$('field-board');board.replaceChildren();const scale=Math.max(1,...(field||[]).map(Math.abs));
    for(let row=7;row>=0;row--) for(let file=0;file<8;file++) {
      const s=row*8+file,cell=document.createElement('span'),value=field?.[s]??0;
      cell.className='field-cell';cell.dataset.value=value;
      if(field) cell.style.backgroundColor=`${value<0?'rgba(224,164,91,':'rgba(104,190,147,'}${.08+Math.abs(value)/scale*.8})`;
      cell.title=field?`${square(s)} · activation ${value} · White ${attacks.white[s>>3]&(1<<(s%8))?'attacks':'—'} · Black ${attacks.black[s>>3]&(1<<(s%8))?'attacks':'—'}`:square(s);
      cell.textContent=file===0?row+1:row===0?'abcdefgh'[file]:'';board.append(cell);
    }
    $('field-range').textContent=field?`${Math.min(...field)} … ${Math.max(...field)}`:'No snapshot yet';
  }
  function showResult(result) {
    updateMetrics({...result,count:result.candidates?.length??0});
    recordTrace(result.cycles,result.nodes);showField(result.field,result.attacks);
    const container=$('candidates');container.replaceChildren();
    $('score-kind').textContent=result.targetDepth===0?'Spatial preference':'Exact scores / labeled bounds';
    $('pv-line').textContent=result.pvSan?.length?'Captured continuation: '+result.pvSan.join(' · ')+' (cache reuse can shorten the line).':'Spatial mode · no searched continuation';
    const ranked=result.candidates.slice().sort((a,b)=>(b.move===result.move)-(a.move===result.move)||((a.bound==='upper')-(b.bound==='upper'))||b.score-a.score).slice(0,5);
    const low=Math.min(...ranked.map(c=>c.score)),high=Math.max(...ranked.map(c=>c.score));
    for(const candidate of ranked) {
      const row=document.createElement('div');row.className='candidate-row'+(candidate.move===result.move?' chosen':'');
      const name=document.createElement('span');name.textContent=game.position.san(candidate.move);name.title=uci(candidate.move);
      const track=document.createElement('span');track.className='candidate-track';
      const bar=document.createElement('i');bar.style.width=`${high===low?100:15+85*(candidate.score-low)/(high-low)}%`;track.append(bar);
      const score=document.createElement('strong');score.textContent=(candidate.bound==='upper'?'≤ ':candidate.bound==='lower'?'≥ ':'')+(candidate.score>0?'+':'')+candidate.score;row.append(name,track,score);container.append(row);
    }
    $('chosen-move').textContent=result.move===null?'—':game.position.san(result.move);
    const parts=$('score-parts');parts.replaceChildren();
    for(const [index,label] of [[6,'Searched value'],[0,'Captures'],[1,'Safety'],[2,'Activity'],[3,'Field'],[4,'Habit'],[5,'Noise']]) {
      const item=document.createElement('div'),name=document.createElement('span'),value=document.createElement('strong');
      name.textContent=label;value.textContent=(result.parts[index]>0?'+':'')+result.parts[index];item.append(name,value);parts.append(item);
    }
    if(result.features&1) {
      const note=document.createElement('p');note.className='console-note';
      note.textContent=`Static root terms: king pressure ${result.staticKing}, mobility ${result.staticMobility}. These describe the board after the chosen move; the searched value includes later positions.`;
      parts.append(note);
    }
  }
  function clearConsole() {
    trace=[];setStage('idle');$('trace-line').setAttribute('points','0,89');
    $('phase-profile').hidden=true;$('pv-line').textContent='The captured continuation appears after a completed search.';
    for(const id of ['decision','nodes','search-depth','node-rate','cutoffs','cache-hits','cache-stores','legal-count','chosen-move','engine-clock','tactical-depth','cache-cutoffs','see-calls']) $(id).textContent='—';
    $('search-detail').textContent='Waiting for a move';$('trace-caption').textContent='Measured nodes over FPGA time. Samples arrive over SPI.';
    $('candidates').replaceChildren();$('score-parts').replaceChildren();showField(null);
  }
  function scheduleTurn() {
    clearTimeout(autoTimer);autoTimer=null;
    if(busy||paused||game.outcome()||claimed||mode==='local'||!connected) return;
    if(!isHumanTurn()) autoTimer=setTimeout(()=>engineTurn(),mode==='watch'?650:80);
    else if(mode==='speed'&&!clockDeadline) {clockDeadline=Date.now()+(clockLeft??roundSeconds*1000);clockLeft=null;paintClock();save();}
  }
  function pauseGame() {
    clearTimeout(autoTimer);autoTimer=null;paused=true;
    if(clockDeadline) {clockLeft=Math.max(0,clockDeadline-Date.now());clockDeadline=0;}
    if(searching) cancel=true;
    cancelDrag();save();render();message(searching?'Stopping the search…':'Game paused. Resume when ready.');
  }
  async function engineTurn(spatial=false) {
    if(busy||paused||!connected||game.outcome()||claimed||(isHumanTurn()&&!(spatial&&mode==='speed'))) return;
    clearTimeout(autoTimer);autoTimer=null;resetClock();promotionFinish?.(null);clearDrag();
    busy=true;searching=true;cancel=false;selected=null;trace=[];$('trace-line').setAttribute('points','0,89');
    const mover=game.position.turn,depth=spatial?0:Number($('depth').value);
    render();$('status').textContent=spatial?'Time’s up. Spatial takes the move.':`${colorName(mover)} · FPGA thinking…`;
    message(spatial?'The countdown expired. The FPGA is choosing your move in Spatial mode.':'Exploring moves on the FPGA.');
    try {
      const result=await fpga.evaluate(game,{depth,timeSeconds:Number($('time').value),cancelled:()=>cancel,stage:setStage,
        progress:status=>{
          const t=status.telemetry;
          if(status.busy) setStage(t?.nodes>0?'search':'field',`FSM ${status.state} · ${colorName(mover)}`);
          if(depth&&status.busy) $('status').textContent=`${colorName(mover)} · searching ${status.searchDepth||depth} ply…`;
          updateMetrics({...t,cycles:status.cycles,count:status.count,depth:status.completedDepth,targetDepth:depth});
          if(status.sampled) recordTrace(status.cycles,t?.nodes);
        }});
      if(result.move!==null) {
        showResult(result);if(spatial) assisted.push(game.history.length);game.push(result.move);
      }
      setStage('complete');save();
      message(game.outcome()?.text||(spatial?'Spatial played your move ⚡. Now the opponent replies.':mode==='watch'?`${colorName(mover)} has moved. ${colorName(game.position.turn)} is next.`:result.budgetExpired?`Completed ${result.depth} ply within the available budget.`:mode==='speed'?'Your countdown starts now.':'Your move.'));
    } catch(error) {
      paused=true;setStage(cancel?'stopped':'error');
      if(cancel) message('Search stopped. Resume when ready.');
      else {message(error.message,true);connection(false);}
    } finally {busy=false;searching=false;render();scheduleTurn();}
  }
  async function choosePromotion(moves) {
    const dialog=$('promotion'),options=$('promotion-options');options.replaceChildren();
    return new Promise(resolve=>{
      const finish=move=>{if(promotionFinish!==finish)return;promotionFinish=null;dialog.close();dialog.oncancel=null;resolve(move);};
      promotionFinish=finish;
      for(const move of moves.slice().reverse()) {
        const pr=decode(move).promotion,button=document.createElement('button');
        button.setAttribute('aria-label',names[pr]);button.title=names[pr];button.append(pieceElement(pr|(game.position.turn<<3)));button.onclick=()=>finish(move);options.append(button);
      }
      $('promotion-cancel').onclick=()=>finish(null);dialog.oncancel=event=>{event.preventDefault();finish(null);};dialog.showModal();
    });
  }
  async function clickSquare(s) {
    if(!canMove()) return;
    const p=game.position;
    if(selected!==null) {
      const choices=legal.filter(m=>{const d=decode(m);return d.from===selected&&d.to===s;});
      if(choices.length) {
        const moveNumber=game.history.length,move=choices.length>1?await choosePromotion(choices):choices[0];
        if(move===null||!canMove()||moveNumber!==game.history.length) return;
        game.push(move);resetClock();selected=null;save();render();scheduleTurn();return;
      }
    }
    selected=p.board[s]&&(p.board[s]>>3)===p.turn?(selected===s?null:s):null;render();
  }
  $('connect').onclick=connect;
  $('theme').onclick=()=>applyTheme(document.documentElement.dataset.theme==='dark'?'light':'dark');
  $('new-game').onclick=async()=>{
    clearTimeout(autoTimer);cancelDrag();promotionFinish?.(null);resetClock();
    game.reset();claimed=false;mode=$('mode').value;roundSeconds=Number($('round-seconds').value);
    human=mode==='local'||mode==='watch'?0:Number($('side').value);flipped=!!human;selected=null;assisted=[];paused=false;
    clearConsole();save();render();message(modeHelp[mode]);scheduleTurn();
  };
  $('mode').onchange=()=>{settingsHelp();message('Start a new game to use this game mode.');};
  $('round-seconds').onchange=()=>message('The move timer applies to your next new game.');
  $('side').onchange=()=>message('Your color will apply when you start a new game.');
  $('depth').onchange=save;
  $('time').onchange=save;
  $('flip').onclick=()=>{cancelDrag();flipped=!flipped;render();};
  $('undo').onclick=()=>{
    clearTimeout(autoTimer);cancelDrag();resetClock();
    if(mode==='local'||mode==='watch') game.undoPly();else game.undoTurn(human);
    paused=mode==='watch'||mode==='speed';
    assisted=assisted.filter(i=>i<game.history.length);selected=null;claimed=false;clearConsole();save();render();message('Previous position restored.');
  };
  $('resume').onclick=()=>{paused=false;render();message(modeHelp[mode]);scheduleTurn();};
  $('stop').onclick=pauseGame;
  $('claim').onclick=()=>{clearTimeout(autoTimer);resetClock();claimed=true;save();render();message('Draw claimed.');};
  $('download').onclick=()=>{
    const result=claimed?'1/2-1/2':game.outcome()?.result||'*';
    const url=URL.createObjectURL(new Blob([game.pgn(result)],{type:'application/x-chess-pgn'}));
    const a=document.createElement('a');a.href=url;a.download='fpga-chess.pgn';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
  };
  let theme='dark';try {theme=localStorage.getItem('fpga-chess-theme')||theme;} catch(_) {}
  setInterval(()=>{
    paintClock();
    if(clockDeadline&&Date.now()>=clockDeadline&&!busy&&!paused&&connected) {clockDeadline=0;clockLeft=0;engineTurn(true);}
  },100);
  document.addEventListener('visibilitychange',()=>{if(document.hidden) save();});
  window.addEventListener('pagehide',save);
  applyTheme(theme);restore();showField(null);render();connect();
})();
