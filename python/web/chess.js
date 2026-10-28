/* Standard chess rules and game history for the browser. There is no move
 * evaluation or computer opponent here: every engine choice comes from SPI. */
(function (root) {
  'use strict';
  const START = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
  const FILES = 'abcdefgh', TYPES = ' pnbrqk';
  const KNIGHTS = [[1,2],[2,1],[2,-1],[1,-2],[-1,-2],[-2,-1],[-2,1],[-1,2]];
  const DIRECTIONS = [[1,0],[-1,0],[0,1],[0,-1],[1,1],[-1,1],[1,-1],[-1,-1]];
  const inside = (x,y) => x>=0 && x<8 && y>=0 && y<8;
  const square = s => FILES[s%8] + (1+Math.floor(s/8));
  const encode = (from,to,promotion=0) => from | (to<<6) | (promotion<<12);
  const decode = m => ({from:m&63, to:(m>>6)&63, promotion:(m>>12)&7});
  const uci = m => { const d=decode(m); return square(d.from)+square(d.to)+(d.promotion?TYPES[d.promotion]:''); };
  class Position {
    constructor(fen=START) {
      const fields=fen.trim().split(/\s+/);
      if (fields.length!==6) throw Error('FEN must have six fields.');
      this.board=new Uint8Array(64);
      const rows=fields[0].split('/');
      if(rows.length!==8) throw Error('FEN must have eight ranks.');
      rows.forEach((row,r)=>{
        let x=0;
        for(const c of row) {
          if(/[1-8]/.test(c)) x+=Number(c);
          else {
            const k=TYPES.indexOf(c.toLowerCase());
            if(k<1 || x>=8) throw Error('Invalid FEN piece.');
            this.board[(7-r)*8+x++]=k | (c===c.toLowerCase()?8:0);
          }
        }
        if(x!==8) throw Error('Invalid FEN rank.');
      });
      if(!['w','b'].includes(fields[1]) || !/^(-|K?Q?k?q?)$/.test(fields[2])) throw Error('Invalid FEN metadata.');
      this.turn=fields[1]==='b'?1:0;
      this.rights=0; 'KQkq'.split('').forEach((c,i)=>{if(fields[2].includes(c)) this.rights|=1<<i;});
      if(!/^(-|[a-h][36])$/.test(fields[3])) throw Error('Invalid en passant square.');
      this.ep=fields[3]==='-'?64:FILES.indexOf(fields[3][0])+8*(Number(fields[3][1])-1);
      this.halfmove=Number(fields[4]); this.fullmove=Number(fields[5]);
      if(!Number.isInteger(this.halfmove) || this.halfmove<0 || !Number.isInteger(this.fullmove) || this.fullmove<1) throw Error('Invalid FEN counters.');
      if(this.board.filter(p=>p===6).length!==1 || this.board.filter(p=>p===14).length!==1) throw Error('Each side needs one king.');
      for(let s=0;s<64;s++) if((s<8||s>=56) && (this.board[s]&7)===1) throw Error('A pawn cannot be on its last rank.');
    }
    clone() {
      const p=Object.create(Position.prototype);
      Object.assign(p,this); p.board=this.board.slice(); return p;
    }
    attacked(s,by) {
      const x=s%8,y=s>>3;
      for(let a=0;a<64;a++) {
        const p=this.board[a],k=p&7;
        if(!k || (p>>3)!==by) continue;
        const dx=x-a%8,dy=y-(a>>3),ax=Math.abs(dx),ay=Math.abs(dy);
        if(k===1 && ax===1 && dy===(by?-1:1)) return true;
        if(k===2 && ax*ay===2) return true;
        if(k===6 && Math.max(ax,ay)===1) return true;
        if((k===3 && ax===ay && ax>0) || (k===4 && ((dx===0)!==(dy===0))) ||
           (k===5 && ((ax===ay && ax>0)||((dx===0)!==(dy===0))))) {
          const sx=Math.sign(dx),sy=Math.sign(dy);
          let cx=a%8+sx,cy=(a>>3)+sy,clear=true;
          while(cx!==x||cy!==y) {if(this.board[cy*8+cx]) {clear=false;break;} cx+=sx;cy+=sy;}
          if(clear) return true;
        }
      }
      return false;
    }
    inCheck(side=this.turn) {const s=this.board.indexOf(6|(side<<3)); return s<0 || this.attacked(s,side^1);}
    legalMoves() {
      const result=[],side=this.turn;
      const add=(a,b)=>{
        const k=this.board[a]&7;
        const promotions=k===1 && (b<8||b>=56)?[2,3,4,5]:[0];
        for(const pr of promotions) {
          const m=encode(a,b,pr),p=this.clone(); p.make(m);
          if(!p.inCheck(side)) result.push(m);
        }
      };
      for(let a=0;a<64;a++) {
        const piece=this.board[a],k=piece&7,x=a%8,y=a>>3;
        if(!k || (piece>>3)!==side) continue;
        if(k===1) {
          const d=side?-1:1,ny=y+d;
          if(inside(x,ny) && !this.board[ny*8+x]) {
            add(a,ny*8+x);
            if(y===(side?6:1) && !this.board[(y+2*d)*8+x]) add(a,(y+2*d)*8+x);
          }
          for(const nx of [x-1,x+1]) if(inside(nx,ny)) {
            const b=ny*8+nx,target=this.board[b];
            if(target && (target>>3)!==side && (target&7)!==6) add(a,b);
            else if(b===this.ep && !target && this.board[b-8*d]===(1|((side^1)<<3))) add(a,b);
          }
        } else {
          const dirs=k===2?KNIGHTS:DIRECTIONS;
          for(let i=0;i<dirs.length;i++) {
            if(k===3 && i<4 || k===4 && i>=4) continue;
            const [dx,dy]=dirs[i]; let nx=x+dx,ny=y+dy;
            while(inside(nx,ny)) {
              const b=ny*8+nx,target=this.board[b];
              if(target && ((target>>3)===side || (target&7)===6)) break;
              add(a,b);
              if(target || k===2 || k===6) break;
              nx+=dx;ny+=dy;
            }
          }
          const home=side?60:4;
          if(k===6 && a===home && !this.inCheck()) {
            const bit=side?4:1,rook=4|(side<<3);
            if((this.rights&bit) && this.board[home+3]===rook && !this.board[home+1] && !this.board[home+2] &&
               !this.attacked(home+1,side^1) && !this.attacked(home+2,side^1)) add(a,home+2);
            if((this.rights&(bit<<1)) && this.board[home-4]===rook && !this.board[home-1] && !this.board[home-2] && !this.board[home-3] &&
               !this.attacked(home-1,side^1) && !this.attacked(home-2,side^1)) add(a,home-2);
          }
        }
      }
      return result;
    }
    make(move) {
      const {from:a,to:b,promotion}=decode(move),p=this.board[a],k=p&7,capture=this.board[b];
      if(k===1 && b===this.ep && !capture && a%8!==b%8) this.board[b+(this.turn?8:-8)]=0;
      this.board[a]=0; this.board[b]=promotion?(promotion|(p&8)):p;
      if(k===6) {
        this.rights &= this.turn?3:12;
        if(Math.abs(b-a)===2) {
          const src=b>a?a+3:a-4,dst=b>a?a+1:a-1;
          this.board[dst]=this.board[src];this.board[src]=0;
        }
      }
      for(const [s,bit] of [[7,1],[0,2],[63,4],[56,8]]) if(a===s||b===s) this.rights&=~bit;
      this.ep=k===1 && Math.abs(b-a)===16?(a+b)/2:64;
      this.halfmove=k===1||capture?0:this.halfmove+1;
      if(this.turn) this.fullmove++;
      this.turn^=1;
      return this;
    }
    positionBytes() {return Uint8Array.from([...this.board,this.turn,this.rights,this.ep]);}
    fen() {
      const rows=[];
      for(let y=7;y>=0;y--) {
        let row='',empty=0;
        for(let x=0;x<8;x++) {
          const p=this.board[y*8+x];
          if(!p) {empty++;continue;}
          if(empty) {row+=empty;empty=0;}
          const c=TYPES[p&7]; row+=(p&8)?c:c.toUpperCase();
        }
        if(empty) row+=empty; rows.push(row);
      }
      let rights='';'KQkq'.split('').forEach((c,i)=>{if(this.rights&(1<<i)) rights+=c;});
      return `${rows.join('/')} ${this.turn?'b':'w'} ${rights||'-'} ${this.ep===64?'-':square(this.ep)} ${this.halfmove} ${this.fullmove}`;
    }
    key() {
      // Uncapturable en passant targets do not distinguish repeated positions.
      let ep='-';
      if(this.ep!==64 && this.legalMoves().some(m=>{const d=decode(m);return d.to===this.ep&&(this.board[d.from]&7)===1&&d.from%8!==d.to%8;})) ep=square(this.ep);
      const f=this.fen().split(' '); return f.slice(0,3).join(' ')+' '+ep;
    }
    insufficient() {
      const pieces=[];
      this.board.forEach((p,s)=>{if(p&&(p&7)!==6) pieces.push([p,s]);});
      if(pieces.some(([p])=>[1,4,5].includes(p&7))) return false;
      if(pieces.length<=1) return true;
      if(pieces.every(([p])=>(p&7)===3)) {
        const colors=pieces.map(([,s])=>(s%8+(s>>3))%2);return colors.every(c=>c===colors[0]);
      }
      return false;
    }
    san(move) {
      const moves=this.legalMoves(); if(!moves.includes(move)) throw Error('Illegal move.');
      const {from,to,promotion}=decode(move),k=this.board[from]&7;
      let text='';
      if(k===6&&Math.abs(to-from)===2) text=to>from?'O-O':'O-O-O';
      else {
        const capture=!!this.board[to]||(k===1&&from%8!==to%8);
        if(k!==1) {
          text=TYPES[k].toUpperCase();
          const others=moves.filter(m=>{const d=decode(m);return d.to===to&&d.from!==from&&(this.board[d.from]&7)===k;}).map(m=>decode(m).from);
          if(others.length) text+=others.every(s=>s%8!==from%8)?FILES[from%8]:others.every(s=>(s>>3)!==(from>>3))?String(1+(from>>3)):square(from);
        } else if(capture) text=FILES[from%8];
        text+=(capture?'x':'')+square(to)+(promotion?'='+TYPES[promotion].toUpperCase():'');
      }
      const next=this.clone().make(move);
      if(next.inCheck()) text+=next.legalMoves().length?'+':'#';
      return text;
    }
  }
  class Game {
    constructor() {this.reset();}
    reset() {this.position=new Position();this.history=[];this.positions=[this.position.clone()];this.keys=[this.position.key()];}
    push(move) {
      const san=this.position.san(move);
      this.history.push({move,san});this.position.make(move);this.positions.push(this.position.clone());this.keys.push(this.position.key());return san;
    }
    undoPly() {
      if(!this.history.length) return;
      this.history.pop();this.positions.pop();this.keys.pop();
      this.position=this.positions.at(-1).clone();
    }
    captures() {
      const result=[{pieces:[],points:0},{pieces:[],points:0}];
      for(let i=0;i<this.history.length;i++) {
        const before=this.positions[i],{from,to}=decode(this.history[i].move);
        let piece=before.board[to];
        if(!piece&&(before.board[from]&7)===1&&from%8!==to%8) piece=before.board[to+(before.turn?8:-8)];
        if(piece) {result[before.turn].pieces.push(piece);result[before.turn].points+=PIECE_VALUES[piece&7];}
      }
      return result;
    }
    undoTurn(human) {
      if(!this.history.length) return;
      do {this.history.pop();this.positions.pop();this.keys.pop();} while(this.history.length&&this.positions.at(-1).turn!==human);
      this.position=this.positions.at(-1).clone();
    }
    repetition() {const key=this.keys.at(-1);return this.keys.filter(k=>k===key).length;}
    outcome() {
      const p=this.position;
      if(!p.legalMoves().length) return p.inCheck()?{text:`${p.turn?'White':'Black'} wins by checkmate`,result:p.turn?'1-0':'0-1'}:{text:'Draw by stalemate',result:'1/2-1/2'};
      if(p.insufficient()) return {text:'Draw by insufficient material',result:'1/2-1/2'};
      if(this.repetition()>=5) return {text:'Draw by fivefold repetition',result:'1/2-1/2'};
      if(p.halfmove>=150) return {text:'Draw by the 75-move rule',result:'1/2-1/2'};
      return null;
    }
    canClaim() {
      if(this.repetition()>=3||this.position.halfmove>=100) return true;
      // A player may also claim by declaring a legal move that produces the
      // third repetition or completes fifty moves without a capture/pawn move.
      for(const move of this.position.legalMoves()) {
        const next=this.position.clone().make(move);
        if(next.halfmove>=100) return true;
        const key=next.key();
        if(this.keys.filter(k=>k===key).length>=2) return true;
      }
      return false;
    }
    pgn(result='*') {
      const rows=[];for(let i=0;i<this.history.length;i+=2) rows.push(`${i/2+1}. ${this.history[i].san}${this.history[i+1]?' '+this.history[i+1].san:''}`);
      return `[Event "DE0-CV Chess"]\n[Site "Raspberry Pi"]\n[Result "${result}"]\n\n${rows.join(' ')} ${result}\n`;
    }
  }
  const PIECE_VALUES=[0,1,3,3,5,9,0];
  const api={Position,Game,START,encode,decode,uci,square,PIECE_VALUES};
  if(typeof module!=='undefined'&&module.exports) module.exports=api;
  root.ChessRules=api;
})(typeof globalThis!=='undefined'?globalThis:this);
