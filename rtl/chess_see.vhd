-- Serialized swap-off analysis for ambiguous captures. Used for ordering only:
-- pinned non-king attackers are conservatively included; no move is pruned.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.chess_pkg.all;

entity chess_see is
  port(clk,reset,cancel,start : in std_logic; board : in board_t;
    source,destination : in natural range 0 to 63;
    promotion : in natural range 0 to 6; ep_capture : in std_logic;
    done : out std_logic; result : out integer range -32000 to 32000);
end;
architecture rtl of chess_see is
  type state_t is (IDLE, APPLY_INITIAL, SCAN, SCAN_TEST, RAY, SWAP, SWAP_WRITE, FOLD, FOLD_WRITE);
  signal state : state_t := IDLE;
  signal pieces : board_t;
  signal target,scan_square,best_square,ray_square : natural range 0 to 63 := 0;
  signal step : integer range -9 to 9 := 0;
  signal side,target_king : std_logic := '0';
  signal best_value : natural range 0 to 3000 := 3000;
  type gains_t is array(0 to 15) of integer range -32000 to 32000;
  signal gains : gains_t := (others=>0);
  signal depth,fold_index : natural range 0 to 15 := 0;
  signal ready : std_logic := '0';
  signal swap_piece : piece_t := x"0";
  signal swap_value : natural range 0 to 3000 := 0;
  signal swap_prior,fold_left,fold_right : integer range -32000 to 32000 := 0;
  signal initial_piece : piece_t := x"0";
  signal initial_source : natural range 0 to 63 := 0;
  signal initial_value : natural range 0 to 3000 := 0;
  signal initial_promotion : natural range 0 to 6 := 0;
  signal initial_ep : std_logic := '0';
  signal scan_piece : piece_t := x"0";
begin
  done<=ready;
  process(clk)
    variable p,moved : piece_t;
    variable dx,dy,sx,sy,v,capture_value,promo_gain : integer;
    variable hit,aligned : boolean;
  begin
    if rising_edge(clk) then
      if reset='1' or cancel='1' then state<=IDLE; ready<='0';
      else
        case state is
          when IDLE=>
            if start='1' then
              pieces<=board; initial_piece<=board(source); initial_source<=source;
              initial_value<=value(board(destination)); target<=destination;
              initial_promotion<=promotion; initial_ep<=ep_capture;
              ready<='0'; state<=APPLY_INITIAL;
            end if;
          when APPLY_INITIAL=>
              p:=initial_piece; moved:=p; promo_gain:=0;
              if initial_promotion>=2 and initial_promotion<=5 then
                moved:=p(3)&std_logic_vector(to_unsigned(initial_promotion,3)); promo_gain:=value(moved)-100;
              end if;
              pieces(initial_source)<=x"0"; pieces(target)<=moved;
              capture_value:=initial_value;
              if initial_ep='1' then
                capture_value:=100;
                if p(3)='0' then pieces(target-8)<=x"0"; else pieces(target+8)<=x"0"; end if;
              end if;
              gains(0)<=capture_value+promo_gain; depth<=0;
              side<=not p(3); target_king<='0'; if kind(moved)=6 then target_king<='1'; end if;
              scan_square<=0; best_value<=3000; ready<='0'; state<=SCAN;
          when SCAN=>
            scan_piece<=pieces(scan_square); state<=SCAN_TEST;
          when SCAN_TEST=>
            p:=scan_piece; dx:=target mod 8-scan_square mod 8; dy:=target/8-scan_square/8;
            hit:=false; aligned:=false; sx:=0; sy:=0;
            if dx>0 then sx:=1; elsif dx<0 then sx:=-1; end if;
            if dy>0 then sy:=1; elsif dy<0 then sy:=-1; end if;
            if scan_square/=target and kind(p)/=0 and p(3)=side and value(p)<best_value then
              case kind(p) is
                when 1=> hit:=abs(dx)=1 and ((p(3)='0' and dy=1) or (p(3)='1' and dy=-1));
                when 2=> hit:=(abs(dx)=1 and abs(dy)=2) or (abs(dx)=2 and abs(dy)=1);
                when 6=> hit:=abs(dx)<=1 and abs(dy)<=1;
                when 3=> aligned:=abs(dx)=abs(dy);
                when 4=> aligned:=dx=0 or dy=0;
                when 5=> aligned:=dx=0 or dy=0 or abs(dx)=abs(dy);
                when others=>null;
              end case;
            end if;
            if hit then best_value<=value(p); best_square<=scan_square; end if;
            if aligned then
              step<=sy*8+sx; ray_square<=scan_square+sy*8+sx; state<=RAY;
            elsif scan_square=63 then state<=SWAP;
            else scan_square<=scan_square+1; state<=SCAN; end if;
          when RAY=>
            if ray_square=target then
              best_value<=value(scan_piece); best_square<=scan_square;
            end if;
            if ray_square=target or kind(pieces(ray_square))/=0 then
              if scan_square=63 then state<=SWAP; else scan_square<=scan_square+1; state<=SCAN; end if;
            else ray_square<=ray_square+step; end if;
          when SWAP=>
            if target_king='1' or best_value=3000 or depth=15 then
              fold_index<=depth;
              -- A king recapture is disallowed when the target is defended.
              if target_king='1' and best_value/=3000 and depth>0 then fold_index<=depth-1; end if;
              state<=FOLD;
            else
              swap_piece<=pieces(best_square); swap_value<=value(pieces(target));
              swap_prior<=gains(depth); state<=SWAP_WRITE;
            end if;
          when SWAP_WRITE=>
              moved:=swap_piece; promo_gain:=0;
              if kind(moved)=1 and (target/8=0 or target/8=7) then
                moved:=moved(3)&"101"; promo_gain:=800;
              end if;
              gains(depth+1)<=swap_value+promo_gain-swap_prior;
              pieces(best_square)<=x"0"; pieces(target)<=moved; depth<=depth+1;
              target_king<='0'; if kind(moved)=6 then target_king<='1'; end if;
              side<=not side; scan_square<=0; best_value<=3000; state<=SCAN;
          when FOLD=>
            if fold_index=0 then result<=gains(0); ready<='1'; state<=IDLE;
            else
              fold_left<=gains(fold_index-1); fold_right<=gains(fold_index); state<=FOLD_WRITE;
            end if;
          when FOLD_WRITE=>
            v:=fold_left; if -fold_right<v then v:=-fold_right; end if;
            gains(fold_index-1)<=v; fold_index<=fold_index-1; state<=FOLD;
        end case;
      end if;
    end if;
  end process;
end;
