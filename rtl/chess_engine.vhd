-- Shared speculative board, spatial legality filter, and 64 recurrent cells.
-- Host commands are bounded; the evaluator runs independently of SPI traffic.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.chess_pkg.all;

entity chess_engine is
  generic(CLOCK_DIVIDE : positive := 4; TRACE_SEARCH : boolean := false; CLOCK_HZ : positive := 50000000;
    FAST_DESTINATIONS : boolean := true; STACK_LANES : positive := 8; FAST_SOURCES : boolean := true;
    PAWN_LANES : positive := 2; EVAL_LANES : positive := 4;
    ROOT_PVS : boolean := true; ROOT_ORDERING : boolean := true; POSITION_TERMS : boolean := true;
    SEE_ORDERING : boolean := true; QUEUE_LANES : positive := 4);
  port(clk,reset : in std_logic;
    rx_we : in std_logic; rx_address : in natural range 0 to 80; rx_data : in byte_t;
    command : in std_logic; request_length : in natural range 0 to 81;
    request_token : in std_logic_vector(79 downto 0);
    response_done : out std_logic; response_status : out natural range 0 to 3;
    response_length : out natural range 0 to 1024;
    read_address : in natural range 0 to 1023; read_data : out byte_t;
    switches : in std_logic_vector(17 downto 0); keys : in std_logic_vector(3 downto 0);
    panel : out std_logic_vector(31 downto 0);
    activity : out std_logic_vector(17 downto 0) := (others=>'0'));
end;

architecture fabric of chess_engine is
  type state_t is (IDLE, SNAPSHOT, RELAX, PICK, APPLY, SETTLE, INSPECT, SCORE_MOVE, RESTORE, ADVANCE, FINISH, COMMIT_MOVE, LOAD_SCAN, LOAD_FINISH, AUDIT_RESET, AUDIT_CELL, AUDIT_DONE, LOAD_POLICY, BOOT_POLICY, SEARCH_SAVE, SEARCH_BEGIN, SEARCH_RECALL_WAIT, SEARCH_RECALL_COPY, SEARCH_ACCEPT, SEARCH_RETURN, SEARCH_ROOT, LOAD_ROUTES, SEARCH_SUM, SEARCH_ADD, SEARCH_SCORE,
    CACHE_CLEAR, EVAL_PAWNS, EVAL_BLEND, EVAL_DONE, CACHE_PROBE, NODE_READY, MOVE_SELECT, MOVE_APPLY,
    EVAL_DRAIN, EVAL_MOBILITY, SEE_WAIT, EVAL_REDUCE, EVAL_DIVIDE, EVAL_PAWN_DRAIN);
  signal state : state_t := IDLE;
  signal phase : natural range 0 to CLOCK_DIVIDE-1 := 0;
  signal command_seen : std_logic := '0';
  signal base,b : board_t := initial_board;
  signal rx : bytes_t(0 to 80) := (others=>x"00");
  signal packet_rx : bytes_t(0 to 80);
  signal packet_length : natural range 0 to 81 := 0;
  signal packet_token : std_logic_vector(79 downto 0) := (others=>'0');
  signal command_pending : std_logic := '0';
  signal cfg : bytes_t(0 to 15) := (
    0=>x"20",1=>x"18",2=>x"20",3=>x"08",4=>x"20",5=>x"10",6=>x"08",7=>x"08",
    8=>x"08",9=>x"04",10=>x"04",11=>x"00",12=>x"00",13=>x"00",14=>x"00",15=>x"00",others=>x"FF");
  signal route_table : bytes_t(0 to 63);
  signal snapshot_table : bytes_t(0 to 63);
  signal route_q,route_host_q,snapshot_q : byte_t;
  signal route_index : natural range 0 to 63 := 0;
  signal route_address : natural range 0 to 63;
  signal field_leds : std_logic_vector(15 downto 0) := (others=>'0');
  signal field_valid : std_logic_vector(63 downto 0) := (others=>'0');
  constant INIT_POLICY : bytes_t(0 to 127) := policy_defaults;
  signal policy : bytes_t(0 to 44) := INIT_POLICY(0 to 44);
  attribute ramstyle : string;
  attribute ramstyle of route_table,snapshot_table : signal is "M10K, no_rw_check";
  signal policy_initialized : std_logic := '0';
  signal policy_boot_index : natural range 0 to 127 := 0;
  signal mem_policy_we,mem_cell_we : std_logic;
  signal mem_policy_data,mem_cell_data : byte_t;
  signal mem_policy_b_address : natural range 0 to 127 := 64;
  signal mem_policy_a,mem_policy_b,mem_field_a,mem_field_b : byte_t;
  signal cell_address_a : natural range 0 to 63 := 0;
  signal table_address_a : natural range 0 to 127 := 0;
  signal policy_index : natural range 0 to 63 := 0;
  signal neuron_result,neuron_output : integer range -127 to 127 := 0;
  signal neuron_old,neuron_bias : signed(7 downto 0) := (others=>'0');
  signal policy_page : natural range 0 to 1 := 0;
  type history_t is array(0 to 7) of std_logic_vector(15 downto 0);
  signal history : history_t := (others=>(others=>'0'));
  signal history_count : natural range 0 to 8 := 0;
  signal nonpawn_count,load_nonpawn : natural range 0 to 64 := 14;
  signal audit_trial : std_logic := '0';
  signal audit_index : natural range 0 to 63 := 0;
  signal audit_own_max,audit_enemy_max : integer range 0 to 2000 := 0;
  signal audit_own_sum,audit_enemy_sum : integer range 0 to 64000 := 0;
  signal audit_position,base_position : integer range -131072 to 131071 := 0;
  signal base_own_risk,base_enemy_risk : integer range 0 to 18000 := 0;
  signal base_minor_home,audit_minor_home : natural range 0 to 16 := 0;
  signal score_safety,score_progress,score_habit : integer range -131072 to 131071 := 0;
  signal neuron_direction : natural range 0 to 9 := 0;
  signal neighbor_accum : signed(13 downto 0) := (others=>'0');
  -- Pack adjacent squares into one RAM word. Eight lanes restore a rank at a
  -- time while retaining one shared spatial fabric and search controller.
  constant STACK_WORDS : positive := 64/STACK_LANES;
  subtype stack_word_t is std_logic_vector(STACK_LANES*4-1 downto 0);
  type stack_ram_t is array(0 to SEARCH_LEVELS*STACK_WORDS-1) of stack_word_t;
  signal search_stack : stack_ram_t;
  attribute ramstyle of search_stack : signal is "M10K";
  signal search_q : stack_word_t;
  signal stack_group_index : natural range 0 to 63 := 0;
  signal stack_group_active : std_logic := '0';
  signal search_sp : natural range 0 to SEARCH_LEVELS-1 := 0;
  signal search_index : natural range 0 to 63 := 0;
  signal search_active,search_returning : std_logic := '0';
  type search_scores_t is array(0 to SEARCH_LEVELS-1) of integer range -30000 to 30000;
  type search_squares_t is array(0 to SEARCH_LEVELS-1) of natural range 0 to 63;
  type search_eps_t is array(0 to SEARCH_LEVELS-1) of natural range 0 to 64;
  type search_promotions_t is array(0 to SEARCH_LEVELS-1) of natural range 2 to 5;
  type search_rights_t is array(0 to SEARCH_LEVELS-1) of std_logic_vector(3 downto 0);
  signal node_static,node_best,node_alpha,node_beta : search_scores_t := (others=>0);
  signal node_wk,node_bk,cursor_src,cursor_dst : search_squares_t := (others=>0);
  signal node_ep : search_eps_t := (others=>64);
  signal cursor_promotion : search_promotions_t := (others=>2);
  signal node_rights : search_rights_t := (others=>"0000");
  signal node_turn,node_check,node_legal,cursor_promoting : std_logic_vector(0 to SEARCH_LEVELS-1) := (others=>'0');
  type node_moves_t is array(0 to SEARCH_LEVELS-1) of std_logic_vector(15 downto 0);
  type node_counts_t is array(0 to SEARCH_LEVELS-1) of natural range 0 to SEARCH_MOVES;
  type node_hashes_t is array(0 to SEARCH_LEVELS-1) of hash_t;
  signal node_count,node_remaining : node_counts_t := (others=>0);
  signal node_hash : node_hashes_t := (others=>(others=>'0'));
  signal node_start_alpha,node_start_beta : search_scores_t;
  signal node_best_move,node_hint,node_killer1,node_killer2 : node_moves_t := (others=>(others=>'0'));
  signal node_hint_valid,node_tactical,node_cached,node_repetition : std_logic_vector(0 to SEARCH_LEVELS-1) := (others=>'0');
  signal node_draw : std_logic_vector(0 to SEARCH_LEVELS-1) := (others=>'0');
  signal node_cache_word : std_logic_vector(127 downto 0);
  signal search_building : std_logic := '0';
  signal search_iteration,search_completed : natural range 0 to MAX_SEARCH_DEPTH := 0;
  signal search_timed_out,search_has_completed,search_running : std_logic := '0';
  signal search_limit : unsigned(47 downto 0) := (others=>'0');
  signal search_epoch : unsigned(15 downto 0) := (others=>'0');
  signal search_cache_hits,search_cache_stores : unsigned(31 downto 0) := (others=>'0');
  signal search_hash_acc : hash_t := (others=>'0');
  signal search_scan,search_pick_index : natural range 0 to SEARCH_MOVES-1 := 0;
  signal search_pick_data : std_logic_vector(31 downto 0) := (others=>'0');
  signal search_clear_index : natural range 0 to CACHE_ENTRIES-1 := 0;
  signal queue_we,cache_we,history_we : std_logic := '0';
  signal queue_write_address,queue_read_address : natural range 0 to SEARCH_LEVELS*SEARCH_MOVES-1 := 0;
  signal queue_write_data,queue_data : std_logic_vector(31 downto 0);
  signal queue_words : words4_t;
  type queue_indices_t is array(0 to 1) of natural range 0 to SEARCH_MOVES-1;
  signal queue_pair_index : queue_indices_t := (others=>0);
  signal queue_pair_data : words4_t := (others=>(others=>'0'));
  signal queue_top_data : std_logic_vector(31 downto 0) := (others=>'0');
  signal queue_top_index,queue_read_base : natural range 0 to SEARCH_MOVES-1 := 0;
  signal queue_read_remaining : natural range 0 to SEARCH_MOVES := 0;
  signal cache_write_address,cache_read_address : natural range 0 to CACHE_ENTRIES-1 := 0;
  signal cache_write_data,cache_data : std_logic_vector(127 downto 0);
  signal history_write_address,history_read_address : natural range 0 to 4095 := 0;
  signal history_write_data,history_data : unsigned(12 downto 0);
  signal hash_data : hash_t;
  signal hash_piece : piece_t;
  signal hash_pieces : pieces4_t;
  signal hash_keys : hashes4_t;
  type lane_scores_t is array(0 to 3) of integer range -32768 to 32767;
  signal eval_lane_mg,eval_lane_eg,eval_pair_mg,eval_pair_eg : lane_scores_t := (others=>0);
  signal eval_pipe_valid : std_logic_vector(1 downto 0) := "00";
  signal eval_mob_index : natural range 0 to 63 := 0;
  signal eval_mob_total,eval_king : integer range -8192 to 8191 := 0;
  signal root_static_mobility,root_static_king,chosen_static_mobility,chosen_static_king : integer range -8192 to 8191 := 0;
  signal completed_static_mobility,completed_static_king : integer range -8192 to 8191 := 0;
  signal spatial_source : natural range 0 to 63;
  type files_t is array(0 to 7) of natural range 0 to 16;
  type ranks_t is array(0 to 7) of natural range 0 to 7;
  signal eval_white_pawns,eval_black_pawns,eval_white_rooks,eval_black_rooks : files_t := (others=>0);
  signal eval_white_min,eval_black_min : ranks_t := (others=>7);
  signal eval_white_max,eval_black_max : ranks_t := (others=>0);
  signal eval_white_bishops,eval_black_bishops : natural range 0 to 16 := 0;
  signal eval_minors,eval_knights : natural range 0 to 32 := 0;
  signal eval_heavy : std_logic := '0';
  signal eval_bishop_colors : std_logic_vector(1 downto 0) := "00";
  signal eval_mg,eval_eg : integer range -131072 to 131071 := 0;
  type pawn_pair_t is array(0 to 1) of integer range -131072 to 131071;
  signal eval_pawn_mg,eval_pawn_eg,eval_pawn_weighted_mg,eval_pawn_weighted_eg : pawn_pair_t := (others=>0);
  signal eval_pawn_valid : std_logic_vector(1 downto 0) := "00";
  signal eval_blend_mg,eval_blend_eg : integer range -4194304 to 4194303 := 0;
  signal eval_dividend : unsigned(20 downto 0) := (others=>'0');
  signal eval_div_product : third_product_t := (others=>'0');
  signal eval_negative : std_logic := '0';
  signal eval_phase : natural range 0 to 256 := 0;
  signal eval_file : natural range 0 to 7 := 0;
  signal active_turn : std_logic;
  signal active_rights : std_logic_vector(3 downto 0);
  signal active_ep : natural range 0 to 64;
  signal active_wk,active_bk : natural range 0 to 63;
  signal search_result,trial_static,base_static,audit_static : integer range -32768 to 32767 := 0;
  signal search_root_move : std_logic_vector(15 downto 0);
  signal search_parts : std_logic_vector(95 downto 0);
  signal search_delta_score : integer range -32768 to 32767 := 0;
  signal root_alpha : integer range -30000 to 30000 := -30000;
  signal root_window_alpha : integer range -30000 to 30000 := -30000;
  signal root_scout,root_research,root_pv_first : std_logic := '0';
  signal root_bound : natural range 0 to 2 := 0;
  signal search_cache_cutoffs,root_researches : unsigned(31 downto 0) := (others=>'0');
  type phase_counters_t is array(0 to 6) of unsigned(47 downto 0);
  signal phase_counters : phase_counters_t := (others=>(others=>'0'));
  signal max_tactical_depth : natural range 0 to SEARCH_LEVELS := 0;
  signal stats_snapshot : bytes_t(0 to 127) := (others=>x"00");
  constant PV_BITS : positive := SEARCH_LEVELS*16;
  subtype pv_word_t is std_logic_vector(PV_BITS+3 downto 0);
  type pv_ram_t is array(0 to SEARCH_LEVELS-1) of pv_word_t;
  signal pv_ram : pv_ram_t;
  attribute ramstyle of pv_ram : signal is "M10K, no_rw_check";
  signal pv_q,pv_write_data : pv_word_t := (others=>'0');
  signal pv_write_enable : std_logic := '0';
  signal pv_write_address,pv_read_address : natural range 0 to SEARCH_LEVELS-1 := 0;
  signal root_pv,iteration_pv,completed_pv : std_logic_vector(PV_BITS-1 downto 0) := (others=>'0');
  signal root_pv_length,iteration_pv_length,completed_pv_length : natural range 0 to SEARCH_LEVELS := 0;
  signal search_sum_a,search_sum_b,search_sum_c : integer range -131072 to 131071 := 0;
  signal search_nodes,search_cutoffs : unsigned(31 downto 0) := (others=>'0');
  -- One shared random stream replaces 64 register/mux banks to make room
  -- for real lookahead. Each serialized cell samples at a different clock.

  signal rng : unsigned(31 downto 0) := x"D0E2C35F";
  signal field_rng : unsigned(31 downto 0) := x"D0E2C35F";
  signal white_a,black_a,reach : std_logic_vector(63 downto 0);
  signal source_available : std_logic_vector(63 downto 0);
  signal white_map,black_map : std_logic_vector(63 downto 0) := (others=>'0');
  signal friend_a,enemy_a : std_logic_vector(63 downto 0);
  signal turn : std_logic := '0';
  signal rights : std_logic_vector(3 downto 0) := "1111";
  signal ep : natural range 0 to 64 := 64;
  signal src,dst : natural range 0 to 63 := 0;
  signal promotion : natural range 2 to 5 := 2;
  signal wk,bk,own_king : natural range 0 to 63 := 4;
  signal trial_king : natural range 0 to 63 := 4;
  signal moving,captured : piece_t := x"0";
  signal en_passant,castling,promoting : std_logic := '0';
  signal in_check,done : std_logic := '0';
  signal legal_count : natural range 0 to 256 := 0;
  signal best_move : std_logic_vector(15 downto 0) := (others=>'0');
  signal best_score : integer range -32768 to 32767 := -32768;
  signal candidate_move : std_logic_vector(15 downto 0);
  type candidates_t is array(0 to 511) of std_logic_vector(143 downto 0);
  signal candidates : candidates_t;
  signal candidate_word : std_logic_vector(143 downto 0);
  signal candidate_index : natural range 0 to 511 := 0;
  signal detail_record : natural range 0 to 3 := 0;
  signal detail_byte,detail_byte_q : natural range 0 to 17 := 0;
  signal candidate_we : std_logic := '0';
  signal candidate_write_index : natural range 0 to 511 := 0;
  signal candidate_bank,published_bank : natural range 0 to 1 := 0;
  signal completed_count : natural range 0 to 256 := 0;
  signal completed_move : std_logic_vector(15 downto 0) := (others=>'0');
  signal completed_score : integer range -32768 to 32767 := -32768;
  signal candidate_write_data : std_logic_vector(143 downto 0);
  attribute ramstyle of candidates : signal is "M10K";
  signal response_kind : natural range 0 to 19 := 0;
  signal candidate_meta : bytes_t(0 to 511);
  attribute ramstyle of candidate_meta : signal is "M10K";
  signal candidate_meta_q : byte_t;
  signal see_start,see_done,see_cancel,see_ep : std_logic := '0';
  signal see_promotion : natural range 0 to 6 := 0;
  signal see_result : integer range -32000 to 32000 := 0;
  signal see_move : std_logic_vector(15 downto 0);
  signal see_calls,see_cycles : unsigned(31 downto 0) := (others=>'0');
  signal response_request,candidate_request,queue_request,cache_request,history_request,pv_request,see_request : std_logic := '0';
  signal page : natural range 0 to 63 := 0;
  signal response_status_i : natural range 0 to 3 := 0;
  signal elapsed : unsigned(47 downto 0) := (others=>'0');
  signal status_cycles : unsigned(47 downto 0) := (others=>'0');
  signal generation : unsigned(31 downto 0) := (others=>'0');
  signal neuron_index : natural range 0 to 63 := 0;
  signal load_index,load_wk,load_bk : natural range 0 to 63 := 0;
  signal load_white_kings,load_black_kings : natural range 0 to 2 := 0;
  signal load_invalid : std_logic := '0';
  signal relax_left : natural range 0 to 255 := 0;
  signal relax_timer : unsigned(19 downto 0) := (others=>'0');
  signal divider : unsigned(15 downto 0) := (others=>'0');
  signal old_keys : std_logic_vector(3 downto 0) := (others=>'0');
  signal last_token : std_logic_vector(79 downto 0) := (others=>'0');
  signal have_token : std_logic := '0';
  signal cached_status : natural range 0 to 3 := 0;
  signal ack : byte_t := x"00";
  signal score_capture,score_danger,score_field,score_noise : integer range -131072 to 131071 := 0;
  signal score_field_sample : signed(7 downto 0) := (others=>'0');
  signal read_byte : byte_t;
  function advance_rng(sample : unsigned(31 downto 0); clocks : natural) return unsigned is
    variable future : unsigned(31 downto 0) := sample;
  begin
    for i in 1 to clocks loop
      future:=future(30 downto 0)&(future(31) xor future(21) xor future(1) xor future(0));
    end loop;
    return future;
  end;
begin
  assert CLOCK_DIVIDE>=4
    report "Search RAM pipelines and timing constraints require a divide of at least four" severity failure;
  assert STACK_LANES=1 or STACK_LANES=2 or STACK_LANES=4 or STACK_LANES=8
    report "Board stack supports 1, 2, 4 or 8 parallel square lanes" severity failure;
  assert PAWN_LANES=1 or PAWN_LANES=2
    report "Pawn evaluator supports one or two parallel file lanes" severity failure;
  assert EVAL_LANES=1 or EVAL_LANES=4 report "Evaluator supports one or four lanes" severity failure;
  assert QUEUE_LANES=1 or QUEUE_LANES=4 report "Move selector supports one or four lanes" severity failure;
  assert SEARCH_LEVELS<=14 report "Protocol 5 continuation and cache stack fields support at most fourteen levels" severity failure;
  -- Decode intent only on the common controller enable. Native RAM/bridge
  -- strobes occupy the following phase, preserving their original write edge.
  -- The long move-decode cone ends at CE registers, not native pulse flops.
  response_done <= response_request when phase=1 else '0';
  candidate_we <= candidate_request when phase=1 else '0';
  queue_we <= queue_request when phase=1 else '0';
  cache_we <= cache_request when phase=1 else '0';
  history_we <= history_request when phase=1 else '0';
  pv_write_enable <= pv_request when phase=1 else '0';
  see_start <= see_request when phase=1 else '0';
  storage : entity work.chess_search_memory port map(clk=>clk,
    queue_we=>queue_we,queue_write_address=>queue_write_address,queue_read_address=>queue_read_address,
    queue_write_data=>queue_write_data,queue_data=>queue_data,
    cache_we=>cache_we,cache_write_address=>cache_write_address,cache_read_address=>cache_read_address,
    cache_write_data=>cache_write_data,cache_data=>cache_data,
    history_we=>history_we,history_write_address=>history_write_address,history_read_address=>history_read_address,
    history_write_data=>history_write_data,history_data=>history_data,
    hash_piece=>hash_piece,hash_square=>search_index,hash_data=>hash_data,
    hash_pieces=>hash_pieces,hash_group=>search_index/4,hash_keys=>hash_keys,queue_words=>queue_words);
  hash_piece<=b(search_index);
  hash_lanes : for lane in 0 to 3 generate hash_pieces(lane)<=b((search_index/4)*4+lane); end generate;
  queue_read_address<=search_sp*SEARCH_MOVES+search_scan;
  cache_read_address<=to_integer(node_hash(search_sp)(CACHE_INDEX_BITS-1 downto 0));
  history_read_address<=src*64+dst;
  spatial_source<=eval_mob_index when state=EVAL_MOBILITY else src;
  spatial : entity work.chess_spatial port map(board=>b,source=>spatial_source,
    white_attack=>white_a,black_attack=>black_a,reachable=>reach);
  see_cancel<='0' when state=SEE_WAIT else '1';
  exchange : entity work.chess_see port map(clk=>clk,reset=>reset,cancel=>see_cancel,start=>see_start,
    board=>b,source=>src,destination=>dst,promotion=>see_promotion,ep_capture=>see_ep,
    done=>see_done,result=>see_result);
  active_turn <= node_turn(search_sp) when search_active='1' else turn;
  source_cells : for s in 0 to 63 generate
    source_available(s)<='1' when b(s)(2 downto 0)/="000" and b(s)(3)=active_turn else '0';
  end generate;
  active_rights <= node_rights(search_sp) when search_active='1' else rights;
  active_ep <= node_ep(search_sp) when search_active='1' else ep;
  active_wk <= node_wk(search_sp) when search_active='1' else wk;
  active_bk <= node_bk(search_sp) when search_active='1' else bk;
  friend_a <= white_a when active_turn='0' else black_a;
  enemy_a <= black_a when active_turn='0' else white_a;
  own_king <= active_wk when active_turn='0' else active_bk;
  response_status <= response_status_i;
  candidate_move <= '0' & std_logic_vector(to_unsigned(promotion,3)) &
    std_logic_vector(to_unsigned(dst,6)) & std_logic_vector(to_unsigned(src,6)) when promoting='1' else
    "0000" & std_logic_vector(to_unsigned(dst,6)) & std_logic_vector(to_unsigned(src,6));
  panel <= best_move & std_logic_vector(to_unsigned(legal_count,9)) & turn & done & in_check &
    std_logic_vector(to_unsigned(state_t'pos(state) mod 16,4));
  activity(16)<=turn;
  activity(17)<='1' when state/=IDLE else '0';
  activity(15 downto 0)<=field_leds;

  -- A single synchronous read port preserves M10K inference for candidates.
  -- Explanation replies contain exactly four 18-byte records. Bounded
  -- comparisons replace a general divide/modulo network on the native host
  -- read port. Its byte selector is registered alongside the RAM word.
  process(all) begin
    detail_record<=0; detail_byte<=0;
    if read_address<18 then detail_byte<=read_address;
    elsif read_address<36 then detail_record<=1; detail_byte<=read_address-18;
    elsif read_address<54 then detail_record<=2; detail_byte<=read_address-36;
    elsif read_address<72 then detail_record<=3; detail_byte<=read_address-54;
    end if;
  end process;
  candidate_index <= published_bank*256+page*4 + detail_record when response_kind=14 else
                     published_bank*256+(page mod 16)*16 + (read_address/4 mod 16);
  route_address <= policy_boot_index mod 64 when state=BOOT_POLICY else
                   route_index when state=LOAD_ROUTES else neuron_index;
  process(clk)
    variable stack_write_word : stack_word_t;
    variable stack_write_index : natural range 0 to 63;
    variable stack_write_valid : boolean;
  begin
    if rising_edge(clk) then
      read_data<=read_byte;
      detail_byte_q<=detail_byte;
      if candidate_we='1' then candidates(candidate_write_index)<=candidate_write_data; end if;
      candidate_word <= candidates(candidate_index);
      candidate_meta_q<=candidate_meta(published_bank*256+(page mod 16)*16+(read_address mod 16));
      if candidate_we='1' then
        candidate_meta(candidate_write_index)<=std_logic_vector(to_unsigned(root_bound*64+search_iteration,8));
      end if;
      pv_q<=pv_ram(pv_read_address);
      if pv_write_enable='1' then pv_ram(pv_write_address)<=pv_write_data; end if;
      route_q <= route_table(route_address);
      route_host_q <= route_table((read_address+48) mod 64);
      snapshot_q <= snapshot_table((read_address+48) mod 64);
      if phase=0 then
        if state=BOOT_POLICY and policy_boot_index<64 then route_table(route_address)<=x"FF";
        elsif state=LOAD_ROUTES then route_table(route_address)<=packet_rx(17+route_index); end if;
      end if;
      if mem_cell_we='1' then snapshot_table(neuron_index)<=mem_cell_data; end if;
      search_q <= search_stack(search_sp*STACK_WORDS+search_index/STACK_LANES);
      stack_write_valid:=false; stack_write_index:=search_index;
      if phase=0 then
        stack_group_active<='0';
        if state=SEARCH_SAVE then
          stack_group_index<=search_index; stack_group_active<='1';
          stack_write_valid:=search_index mod STACK_LANES=0;
        end if;
      elsif stack_group_active='1' and phase<EVAL_LANES/STACK_LANES then
        -- A scalar reference stack writes the rest of the issued group on
        -- intervening native clocks. Four evaluation lanes never skip squares.
        stack_write_valid:=true; stack_write_index:=stack_group_index+phase*STACK_LANES;
      end if;
      if stack_write_valid then
        for lane in 0 to STACK_LANES-1 loop
          stack_write_word(lane*4+3 downto lane*4):=b((stack_write_index/STACK_LANES)*STACK_LANES+lane);
        end loop;
        search_stack(search_sp*STACK_WORDS+stack_write_index/STACK_LANES)<=stack_write_word;
      end if;
      if rx_we='1' then rx(rx_address)<=rx_data; end if;
    end if;
  end process;
  pv_read_address<=0 when state=SEARCH_ROOT else search_sp+1 when search_sp<SEARCH_LEVELS-1 else search_sp;

  -- Three native-clock stages: RAM outputs, two pair winners, group winner.
  -- Their addresses/masks are tagged with the RAM read, not the next cursor.
  process(clk)
    variable left_word,right_word : std_logic_vector(31 downto 0);
    variable pair_index : natural range 0 to SEARCH_MOVES-1;
  begin
    if rising_edge(clk) then
      queue_read_base<=(search_scan/4)*4; queue_read_remaining<=node_remaining(search_sp);
      for pair in 0 to 1 loop
        left_word:=(others=>'0'); right_word:=(others=>'0'); pair_index:=queue_read_base+pair*2;
        if queue_read_base+pair*2<queue_read_remaining then left_word:=queue_words(pair*2); end if;
        if queue_read_base+pair*2+1<queue_read_remaining then right_word:=queue_words(pair*2+1); end if;
        if unsigned(right_word(31 downto 16))>unsigned(left_word(31 downto 16)) then
          left_word:=right_word; pair_index:=queue_read_base+pair*2+1;
        end if;
        queue_pair_data(pair)<=left_word; queue_pair_index(pair)<=pair_index;
      end loop;
      queue_top_data<=queue_pair_data(0); queue_top_index<=queue_pair_index(0);
      if unsigned(queue_pair_data(1)(31 downto 16))>unsigned(queue_pair_data(0)(31 downto 16)) then
        queue_top_data<=queue_pair_data(1); queue_top_index<=queue_pair_index(1);
      end if;
    end if;
  end process;

  -- True dual-port M10K tables. Native-clock RAM reads settle between common
  -- chess enables; these output registers are deliberately not multicycled.
  process(state,neuron_index,neuron_direction,neuron_result,policy_page,policy_index,policy_boot_index,read_address,response_kind,dst)
    variable x,y : integer;
  begin
    cell_address_a<=dst;
    if state=RELAX and neuron_direction<8 then
      x:=neuron_index mod 8+DX(neuron_direction); y:=neuron_index/8+DY(neuron_direction);
      cell_address_a<=0;
      if x>=0 and x<8 and y>=0 and y<8 then cell_address_a<=y*8+x; end if;
    end if;
    table_address_a<=16+neuron_direction;
    if state=BOOT_POLICY then table_address_a<=policy_boot_index;
    elsif state=LOAD_POLICY then table_address_a<=policy_page*64+policy_index;
    elsif response_kind=12 then table_address_a<=policy_page*64+(read_address mod 64);
    elsif neuron_direction=9 then table_address_a<=24+(neuron_result+128)/16;
    end if;
  end process;
  neuron_output<=sat(to_integer(signed(mem_policy_a))) when policy(11)(0)='1' else neuron_result;
  mem_policy_we<='1' when (state=LOAD_POLICY or state=BOOT_POLICY) and phase=0 else '0';
  mem_cell_we<='1' when state=RELAX and neuron_direction=9 and phase=0 and relax_timer=0 and relax_left>0 else '0';
  mem_policy_data<=INIT_POLICY(policy_boot_index) when state=BOOT_POLICY else packet_rx(policy_index+2);
  mem_policy_b_address<=64+neuron_index;
  mem_cell_data<=std_logic_vector(to_signed(neuron_output,8));
  cell_memory : entity work.chess_cell_memory port map(clk=>clk,policy_we=>mem_policy_we,cell_we=>mem_cell_we,
    policy_a=>table_address_a,policy_b=>mem_policy_b_address,cell_a=>cell_address_a,cell_b=>neuron_index,
    policy_data=>mem_policy_data,cell_data=>mem_cell_data,
    policy_q_a=>mem_policy_a,policy_q_b=>mem_policy_b,cell_q_a=>mem_field_a,cell_q_b=>mem_field_b);

  process(all)
    variable n,v : integer;
    variable word32 : std_logic_vector(31 downto 0);
  begin
    n:=read_address; read_byte<=x"00"; v:=0; word32:=(others=>'0');
    case response_kind is
      when 0 =>
        case n is
          when 0=>read_byte<=x"53"; when 1=>read_byte<=x"43"; when 2=>read_byte<=x"46"; when 3=>read_byte<=x"32";
          when 4=>if state/=IDLE then read_byte<=x"01"; end if;
          when 5=>read_byte<="0000000"&done;
          when 6=>read_byte<="0000000"&in_check;
          when 7=>read_byte<="0000000"&turn;
          when 8=>read_byte<=oct(legal_count/256); when 9=>read_byte<=oct(legal_count);
          when 10=>read_byte<=best_move(15 downto 8); when 11=>read_byte<=best_move(7 downto 0);
          when 12=>word32:=std_logic_vector(to_signed(best_score,32)); read_byte<=word32(15 downto 8); when 13=>read_byte<=oct(best_score);
          when 14=>read_byte<=oct(state_t'pos(state)); when 15=>read_byte<=x"05";
          when 16 to 19=>read_byte<=std_logic_vector(status_cycles(31-(n-16)*8 downto 24-(n-16)*8));
          when 20 to 23=>read_byte<=std_logic_vector(generation(31-(n-20)*8 downto 24-(n-20)*8));
          when 24 to 27=>read_byte<=std_logic_vector(rng(31-(n-24)*8 downto 24-(n-24)*8));
          when 28=>read_byte<=oct(search_iteration); when 29=>read_byte<=oct(search_completed);
          when 30=>read_byte<=oct(history_count); when 31=>read_byte<=x"0F";
          when 32 to 35=>word32:=x"0000"&std_logic_vector(status_cycles(47 downto 32));read_byte<=word32(31-(n-32)*8 downto 24-(n-32)*8);
          when 36 to 39=>word32:=std_logic_vector(to_unsigned(CLOCK_HZ,32));read_byte<=word32(31-(n-36)*8 downto 24-(n-36)*8);
          when others=>null;
        end case;
      when 1=>read_byte<=ack;
      when 4=>
        if n<8 then read_byte<=white_map(n*8+7 downto n*8);
        elsif n<16 then read_byte<=black_map((n-8)*8+7 downto (n-8)*8);
        elsif n<80 then
          if field_valid(n-16)='1' then read_byte<=snapshot_q; end if;
        end if;
      when 5=>
        if n<64 then read_byte<="0000"&base(n);
        elsif n=64 then read_byte<="0000000"&turn;
        elsif n=65 then read_byte<="0000"&rights;
        elsif n=66 then read_byte<=oct(ep); end if;
      when 6=>if n<16 then read_byte<=cfg(n); elsif n<80 then read_byte<=route_host_q; end if;
      when 7=>
        read_byte<=candidate_word(143-(n mod 4)*8 downto 136-(n mod 4)*8);
      when 12=>
        if n<64 then read_byte<=mem_policy_a; end if;
      when 14=>
        if n<72 then read_byte<=candidate_word(143-detail_byte_q*8 downto 136-detail_byte_q*8); end if;
      when 19=>if n<16 then read_byte<=candidate_meta_q; end if;
      when 18=>
        if n<128 then read_byte<=stats_snapshot(n); end if;
        -- A command-time snapshot prevents torn multi-byte live counters.
      when others=>null;
    end case;
  end process;

  process(clk)
    variable stats_word : unsigned(31 downto 0);
    variable blend_sum : signed(23 downto 0);
    variable blend_magnitude : unsigned(23 downto 0);
    variable phase_group : natural range 0 to 6;
    variable mob_map : std_logic_vector(63 downto 0);
    variable next_mob : natural range 0 to 64;
    variable w_p,b_p,w_r,b_r : files_t;
    variable w_min,b_min,w_max,b_max : ranks_t;
    variable wb,bb,minors,knights,phase_sum,king_sum : integer;
    variable heavy : std_logic;
    variable bishop_colors : std_logic_vector(1 downto 0);
    variable sub,len,n,k,x,y,neighbor,excitation,noise,total,delta,score : integer;
    variable valid,pawn_double,pawn_ep,castle_ok,king_safe,mutating,duplicate : boolean;
    variable p,t : piece_t;
    variable temp : board_t;
    variable friend_map,enemy_map : std_logic_vector(63 downto 0);
    variable new_rights : std_logic_vector(3 downto 0);
    variable kings_w,kings_b,king_w_square,king_b_square : integer;
    variable seed32 : unsigned(31 downto 0);
    variable neighbor_s,total_s,old_s,excitation_s : signed(13 downto 0);
    variable local_noise : signed(4 downto 0);
    variable weight_product : signed(15 downto 0);
    variable liability : integer range 0 to 2000;
    variable position_delta : integer range -8192 to 8191;
    variable habit : integer range -2048 to 2047;
    variable capture_part,safety_part,field_part : integer range -32768 to 32767;
    variable progress_part : integer range -65536 to 65535;
    variable our_piece,our_attack,their_attack : boolean;
    variable own_k,enemy_k : natural range 0 to 63;
    variable next_static,search_part,search_depth,prom_kind : integer;
    variable tactical,consider_move : boolean;
    variable packed_move : std_logic_vector(15 downto 0);
    variable order_score,mg,eg,ph,file_index,white_bonus,black_bonus,remaining_depth,remaining_q : integer;
    variable white_passed,black_passed,repeated : boolean;
    variable next_hash : hash_t;
    variable picked : std_logic_vector(31 downto 0);
    variable picked_index : natural range 0 to SEARCH_MOVES-1;
    variable cache_word : std_logic_vector(127 downto 0);
    variable destination_mask : std_logic_vector(63 downto 0);
    variable next_destination,next_source : natural range 0 to 64;
  begin
    if rising_edge(clk) then
      -- n is scratch arithmetic, never state carried between controller steps.
      -- In particular, a quiet PICK must not retain EVAL_MOBILITY's popcount.
      n:=0;
      divider<=divider+1;
      if phase=CLOCK_DIVIDE-1 then phase<=0; else phase<=phase+1; end if;
      if command='0' then command_seen<='0'; end if;
      -- Shared PRNG; serial field updates sample different cycles.
      rng <= rng(30 downto 0)&(rng(31) xor rng(21) xor rng(1) xor rng(0));
      if reset='1' then
        response_request<='0'; candidate_request<='0'; queue_request<='0'; cache_request<='0'; history_request<='0'; pv_request<='0'; see_request<='0';
        phase<=0; command_seen<='0'; command_pending<='0'; old_keys<=(others=>'0');
        state<=IDLE;
        if policy_initialized='0' then state<=BOOT_POLICY; policy_boot_index<=0; end if;
        base<=initial_board; b<=initial_board; turn<='0'; rights<="1111"; ep<=64;
        wk<=4; bk<=60; field_valid<=(others=>'0'); field_leds<=(others=>'0');
        done<='0'; in_check<='0'; legal_count<=0; best_score<=-32768; best_move<=(others=>'0');
        generation<=(others=>'0'); elapsed<=(others=>'0'); rng<=x"D0E2C35F"; have_token<='0';
        history_count<=0; nonpawn_count<=14; neuron_direction<=0; neighbor_accum<=(others=>'0');
        neuron_old<=(others=>'0'); neuron_bias<=(others=>'0');
        search_active<='0'; search_sp<=0; search_nodes<=(others=>'0'); search_cutoffs<=(others=>'0');
        search_running<='0'; search_has_completed<='0'; search_completed<=0; search_iteration<=0;
        search_timed_out<='0'; candidate_bank<=0; published_bank<=0;
        search_cache_hits<=(others=>'0'); search_cache_stores<=(others=>'0');
        phase_counters<=(others=>(others=>'0')); eval_pipe_valid<="00"; eval_pawn_valid<="00";
        root_alpha<=-30000; root_scout<='0'; root_research<='0'; root_pv_first<='0'; root_bound<=0;
        completed_pv_length<=0; iteration_pv_length<=0; max_tactical_depth<=0;
        search_cache_cutoffs<=(others=>'0'); root_researches<=(others=>'0');
        see_calls<=(others=>'0'); see_cycles<=(others=>'0');
      elsif phase=0 then
        -- Predict the next enable's PRNG sample. Only a short XOR network
        -- sees native rng; field/root arithmetic uses this enabled register.
        field_rng<=advance_rng(rng,CLOCK_DIVIDE);
        response_request<='0'; candidate_request<='0'; queue_request<='0'; cache_request<='0'; history_request<='0'; pv_request<='0'; see_request<='0';
        old_keys<=keys;
        -- Freeze the received frame at the chess enable boundary before any
        -- decoding or arithmetic. Native RX remains single-cycle constrained;
        -- every evaluator operand now comes from an enabled register bank.
        if command='1' and command_seen='0' then
          packet_rx<=rx; packet_length<=request_length; packet_token<=request_token;
          command_seen<='1'; command_pending<='1';
        end if;
        if state/=IDLE then elapsed<=elapsed+CLOCK_DIVIDE; end if;
        if state/=IDLE then
          phase_group:=6;
          if search_active='0' then phase_group:=0;
          elsif state=SEARCH_SAVE or state=EVAL_DRAIN or state=EVAL_MOBILITY or
                state=EVAL_PAWNS or state=EVAL_BLEND or state=EVAL_REDUCE or
                state=EVAL_DIVIDE or state=EVAL_PAWN_DRAIN or state=EVAL_DONE then phase_group:=1;
          elsif state=SEARCH_RECALL_WAIT or state=SEARCH_RECALL_COPY then phase_group:=4;
          elsif state=MOVE_SELECT or state=MOVE_APPLY then phase_group:=3;
          elsif state=CACHE_PROBE or state=SEARCH_RETURN then phase_group:=5;
          elsif state=PICK or state=APPLY or state=SETTLE or state=INSPECT or state=ADVANCE or state=SEE_WAIT then phase_group:=2;
          end if;
          phase_counters(phase_group)<=phase_counters(phase_group)+CLOCK_DIVIDE;
        end if;
        if state=SEE_WAIT then see_cycles<=see_cycles+CLOCK_DIVIDE; end if;
        eval_pipe_valid<="00";
        if state=SEARCH_SAVE or state=EVAL_DRAIN then
          eval_pipe_valid<=eval_pipe_valid(0)&'0';
          if eval_pipe_valid(0)='1' then
            eval_pair_mg(0)<=eval_lane_mg(0)+eval_lane_mg(1); eval_pair_mg(1)<=eval_lane_mg(2)+eval_lane_mg(3);
            eval_pair_eg(0)<=eval_lane_eg(0)+eval_lane_eg(1); eval_pair_eg(1)<=eval_lane_eg(2)+eval_lane_eg(3);
          end if;
          if eval_pipe_valid(1)='1' then
            eval_mg<=eval_mg+eval_pair_mg(0)+eval_pair_mg(1);
            eval_eg<=eval_eg+eval_pair_eg(0)+eval_pair_eg(1);
          end if;
        end if;
        if state=EVAL_PAWNS or state=EVAL_PAWN_DRAIN then
          eval_pawn_valid<=eval_pawn_valid(0)&'0';
          if eval_pawn_valid(0)='1' then
            for lane in 0 to 1 loop
              eval_pawn_weighted_mg(lane)<=0; eval_pawn_weighted_eg(lane)<=0;
              if lane<PAWN_LANES then
                eval_pawn_weighted_mg(lane)<=eval_pawn_mg(lane)*to_integer(unsigned(policy(13)))/16;
                eval_pawn_weighted_eg(lane)<=eval_pawn_eg(lane)*to_integer(unsigned(policy(13)))/16;
              end if;
            end loop;
          end if;
          if eval_pawn_valid(1)='1' then
            eval_mg<=eval_mg+eval_pawn_weighted_mg(0)+eval_pawn_weighted_mg(1);
            eval_eg<=eval_eg+eval_pawn_weighted_eg(0)+eval_pawn_weighted_eg(1);
          end if;
        end if;
        -- Every register below advances only on this common enable. The SDC
        -- gives only these source/destination banks CLOCK_DIVIDE setup cycles.
        -- Host byte reception, RAM readout and strobes use the native clock.
        -- Registered spatial memory is distributed; a shared neuron ALU
        -- scans it in Gauss-Seidel order. All movement/attack cells remain
        -- concurrent. The shared PRNG saves logic for the search stack.
        if state=RELAX and relax_timer=0 and relax_left>0 then
            n:=neuron_index;
            if neuron_direction<8 then
              -- Capture RAM operands early in the cell's existing microsteps.
              -- The activation arithmetic then runs entirely between CE banks.
              if neuron_direction=0 then
                neuron_old<=(others=>'0');
                if field_valid(n)='1' then neuron_old<=signed(mem_field_b); end if;
                neuron_bias<=signed(mem_policy_b);
              end if;
              x:=n mod 8+DX(neuron_direction); y:=n/8+DY(neuron_direction);
              if x>=0 and x<8 and y>=0 and y<8 and route_q(neuron_direction)='1' and field_valid(cell_address_a)='1' then
                weight_product:=signed(mem_field_a)*signed(mem_policy_a);
                neighbor_accum<=neighbor_accum+resize(shift_right(weight_product,6),14);
              end if;
              neuron_direction<=neuron_direction+1;
            elsif neuron_direction=8 then
            neighbor_s:=neighbor_accum; neighbor_accum<=(others=>'0'); neuron_direction<=0;
            old_s:=resize(neuron_old,14);
            excitation_s:=(others=>'0');
            if friend_a(n)='1' then excitation_s:=resize(signed('0' & cfg(1)(7 downto 1)),14); end if;
            if enemy_a(n)='1' then excitation_s:=excitation_s-resize(signed('0' & cfg(2)(7 downto 1)),14); end if;
            local_noise:=resize(signed(field_rng(3 downto 0)),5);
            if field_rng(7 downto 0)>=unsigned(cfg(0)) then local_noise:=(others=>'0'); end if;
            total_s:=old_s-shift_right(old_s,to_integer(unsigned(policy(14)(2 downto 0))))+
                     shift_right(neighbor_s,2)+excitation_s+resize(local_noise,14)+resize(neuron_bias,14);
            if cfg(3)(0)='1' then total_s:=total_s+shift_right(old_s,3); end if;
            if cfg(3)(1)='1' then total_s:=total_s-shift_right(neighbor_s,1); end if;
            if abs(total_s)<resize(signed('0'&cfg(3)(7 downto 2)),14) then total_s:=(others=>'0'); end if;
            neuron_result<=sat(to_integer(total_s)); neuron_direction<=9;
            else
            field_valid(n)<='1'; neuron_direction<=0;
            if n mod 8=0 then
              field_leds(n/8)<='0'; field_leds(n/8+8)<='0';
              if neuron_output>32 then field_leds(n/8)<='1'; end if;
              if neuron_output< -32 then field_leds(n/8+8)<='1'; end if;
            end if;
            if neuron_index=63 then neuron_index<=0; else neuron_index<=neuron_index+1; end if;
            end if;
        end if;
        case state is
          when BOOT_POLICY=>
            if policy_boot_index=127 then policy_initialized<='1'; state<=IDLE;
            else policy_boot_index<=policy_boot_index+1; end if;
          when LOAD_SCAN=>
            p:=packet_rx(load_index+1)(3 downto 0); b(load_index)<=p;
            if unsigned(packet_rx(load_index+1))>14 or p=x"7" or p=x"8" then load_invalid<='1'; end if;
            if kind(p)=1 and (load_index/8=0 or load_index/8=7) then load_invalid<='1'; end if;
            if p=x"6" then
              load_wk<=load_index;
              if load_white_kings<2 then load_white_kings<=load_white_kings+1; end if;
            end if;
            if p=x"E" then
              load_bk<=load_index;
              if load_black_kings<2 then load_black_kings<=load_black_kings+1; end if;
            end if;
            if kind(p)>=2 and kind(p)<=5 then load_nonpawn<=load_nonpawn+1; end if;
            if load_index=63 then state<=LOAD_FINISH; else load_index<=load_index+1; end if;
          when LOAD_FINISH=>
            response_request<='1'; state<=IDLE;
            if load_invalid='1' or load_white_kings/=1 or load_black_kings/=1 then
              response_status_i<=3; cached_status<=3; b<=base;
            else
              wk<=load_wk; bk<=load_bk; base<=b; nonpawn_count<=load_nonpawn;
              turn<=packet_rx(65)(0); rights<=packet_rx(66)(3 downto 0); ep<=to_integer(unsigned(packet_rx(67)));
              done<='0'; in_check<='0'; legal_count<=0; field_valid<=(others=>'0'); field_leds<=(others=>'0'); generation<=generation+1; history_count<=0;
            end if;
          when IDLE=>
            b<=base; white_map<=white_a; black_map<=black_a; in_check<=enemy_a(own_king);
            if keys(1)='1' and old_keys(1)='0' then state<=SNAPSHOT; done<='0'; end if;
          when SNAPSHOT=>
            search_active<='0'; search_nodes<=(others=>'0'); search_cutoffs<=(others=>'0');
            search_running<='1'; search_has_completed<='0'; search_completed<=0; search_timed_out<='0';
            search_iteration<=0; if unsigned(policy(10))>=2 then search_iteration<=2; end if;
            candidate_bank<=1-published_bank;
            search_limit<=resize(resize(unsigned(policy(40)),48)*to_unsigned(CLOCK_HZ,48),48);
            search_epoch<=search_epoch+1;
            search_cache_hits<=(others=>'0'); search_cache_stores<=(others=>'0');
            phase_counters<=(others=>(others=>'0')); max_tactical_depth<=0;
            search_cache_cutoffs<=(others=>'0'); root_researches<=(others=>'0');
            see_calls<=(others=>'0'); see_cycles<=(others=>'0');
            root_alpha<=-30000; root_pv_first<='0'; root_bound<=0;
            iteration_pv_length<=0; completed_pv_length<=0;
            node_killer1<=(others=>(others=>'0')); node_killer2<=(others=>(others=>'0'));
            white_map<=white_a; black_map<=black_a; in_check<=enemy_a(own_king);
            legal_count<=0; src<=0; dst<=0; promotion<=2; best_score<=-32768;
            best_move<=(others=>'0'); elapsed<=(others=>'0');
            neuron_index<=0; neuron_direction<=0; neighbor_accum<=(others=>'0');
            relax_left<=to_integer(unsigned(cfg(4))); relax_timer<=(others=>'0');
            audit_trial<='0'; state<=AUDIT_RESET;
            if search_epoch=x"FFFF" then search_clear_index<=0; state<=CACHE_CLEAR; end if;
          when CACHE_CLEAR=>
            cache_request<='1'; cache_write_address<=search_clear_index; cache_write_data<=(others=>'0');
            if search_clear_index=CACHE_ENTRIES-1 then state<=AUDIT_RESET;
            else search_clear_index<=search_clear_index+1; end if;
          when RELAX=>
            if relax_timer/=0 then relax_timer<=relax_timer-1;
            elsif relax_left=0 then state<=PICK;
            elsif neuron_index=63 and neuron_direction=9 then relax_left<=relax_left-1; relax_timer<=shift_left(resize(unsigned(cfg(11)),20),12)/CLOCK_DIVIDE; end if;
          when LOAD_ROUTES=>
            if route_index=63 then state<=IDLE; response_request<='1';
            else route_index<=route_index+1; end if;
          when LOAD_POLICY=>
            if policy_page=0 and policy_index<45 then policy(policy_index)<=packet_rx(policy_index+2); end if;
            if policy_index=63 then state<=IDLE; response_request<='1';
            else policy_index<=policy_index+1; end if;
          when AUDIT_RESET=>
            audit_index<=0; audit_own_max<=0; audit_enemy_max<=0; audit_own_sum<=0; audit_enemy_sum<=0;
            audit_position<=0; audit_static<=0; audit_minor_home<=0; state<=AUDIT_CELL;
          when AUDIT_CELL=>
            p:=b(audit_index); k:=kind(p); our_piece:=p(3)=turn;
            our_attack:=friend_a(audit_index)='1'; their_attack:=enemy_a(audit_index)='1';
            liability:=0;
            if k>=1 and k<=5 then
              if (our_piece and their_attack) or (not our_piece and our_attack) then
                liability:=value(p);
                if (our_piece and our_attack) or (not our_piece and their_attack) then liability:=liability*3/4; end if;
              end if;
              if our_piece then
                audit_own_sum<=audit_own_sum+liability;
                if liability>audit_own_max then audit_own_max<=liability; end if;
              else
                audit_enemy_sum<=audit_enemy_sum+liability;
                if liability>audit_enemy_max then audit_enemy_max<=liability; end if;
              end if;
            end if;
            position_delta:=value(p)*to_integer(unsigned(policy(12)))/16+
                            square_wisdom(p,audit_index,nonpawn_count<=4)*to_integer(unsigned(policy(13)))/16;
            if not our_piece then position_delta:=-position_delta; end if;
            audit_static<=clip16(audit_static+position_delta);
            position_delta:=0;
            if k/=0 then
              position_delta:=square_wisdom(p,audit_index,nonpawn_count<=4);
              if not our_piece then position_delta:=-position_delta; end if;
              if our_piece and (k=2 or k=3) and
                 ((turn='0' and audit_index/8=0) or (turn='1' and audit_index/8=7)) then
                audit_minor_home<=audit_minor_home+1;
              end if;
            end if;
            if our_attack then position_delta:=position_delta+centrality(audit_index)*to_integer(unsigned(policy(8))); end if;
            if their_attack then position_delta:=position_delta-centrality(audit_index)*to_integer(unsigned(policy(8))); end if;
            own_k:=own_king; if audit_trial='1' then own_k:=trial_king; end if;
            enemy_k:=bk; if turn='1' then enemy_k:=wk; end if;
            if nonpawn_count>4 then
              if abs(audit_index mod 8-own_k mod 8)<=1 and abs(audit_index/8-own_k/8)<=1 and their_attack then
                position_delta:=position_delta-to_integer(unsigned(policy(9)));
              end if;
              if abs(audit_index mod 8-enemy_k mod 8)<=1 and abs(audit_index/8-enemy_k/8)<=1 and our_attack then
                position_delta:=position_delta+to_integer(unsigned(policy(9)));
              end if;
            end if;
            audit_position<=audit_position+position_delta;
            if audit_index=63 then state<=AUDIT_DONE; else audit_index<=audit_index+1; end if;
          when AUDIT_DONE=>
            if audit_trial='0' then
              base_own_risk<=audit_own_max+audit_own_sum/4;
              base_enemy_risk<=audit_enemy_max+audit_enemy_sum/4;
              base_position<=audit_position; base_static<=audit_static;
              base_minor_home<=audit_minor_home; state<=RELAX;
            else
              score_safety<=clip16((base_own_risk-audit_own_max-audit_own_sum/4)*to_integer(unsigned(policy(0)))/16+
                (audit_enemy_max+audit_enemy_sum/4-base_enemy_risk)*to_integer(unsigned(policy(1)))/16);
              score_progress<=clip16((audit_position-base_position)*to_integer(unsigned(policy(2)))/8);
              state<=SCORE_MOVE;
            end if;
          when PICK=>
            p:=b(src); t:=b(dst); k:=kind(p); delta:=dst-src;
            valid:=false; pawn_double:=false; pawn_ep:=false; castle_ok:=false;
            friend_map:=friend_a; enemy_map:=enemy_a;
            if k/=0 and p(3)=active_turn and src/=dst and kind(t)/=6 and (kind(t)=0 or t(3)/=active_turn) then
              if k/=1 then valid:=reach(dst)='1';
              else
                if src mod 8=dst mod 8 and kind(t)=0 then
                  if (active_turn='0' and delta=8) or (active_turn='1' and delta=-8) then valid:=true; end if;
                  if active_turn='0' and src/8=1 and delta=16 then pawn_double:=kind(b(src+8))=0; end if;
                  if active_turn='1' and src/8=6 and delta=-16 then pawn_double:=kind(b(src-8))=0; end if;
                elsif reach(dst)='1' then
                  if kind(t)/=0 then valid:=true;
                  elsif dst=active_ep then
                    if active_turn='0' and dst/8=5 then pawn_ep:=b(dst-8)=x"9"; end if;
                    if active_turn='1' and dst/8=2 then pawn_ep:=b(dst+8)=x"1"; end if;
                  end if;
                end if;
                valid:=valid or pawn_double or pawn_ep;
              end if;
              if k=6 and ((active_turn='0' and src=4) or (active_turn='1' and src=60)) then
                n:=0; if active_turn='1' then n:=56; end if;
                if dst=n+6 and active_rights(n/28)='1' then
                  castle_ok:=b(n+7)(2 downto 0)="100" and b(n+7)(3)=active_turn and
                    kind(b(n+5))=0 and kind(b(n+6))=0 and enemy_map(n+4)='0' and enemy_map(n+5)='0';
                elsif dst=n+2 and active_rights(n/28+1)='1' then
                  castle_ok:=b(n)(2 downto 0)="100" and b(n)(3)=active_turn and
                    kind(b(n+1))=0 and kind(b(n+2))=0 and kind(b(n+3))=0 and
                    enemy_map(n+4)='0' and enemy_map(n+3)='0';
                end if;
                valid:=valid or castle_ok;
              end if;
            end if;
            moving<=p; captured<=t; en_passant<='0'; castling<='0'; promoting<='0'; trial_king<=own_king;
            if pawn_ep then en_passant<='1'; captured<=(not active_turn)&"001"; end if;
            if castle_ok then castling<='1'; end if;
            if k=1 and (dst/8=0 or dst/8=7) then promoting<='1'; end if;
            packed_move:="0000"&std_logic_vector(to_unsigned(dst,6))&std_logic_vector(to_unsigned(src,6));
            if k=1 and (dst/8=0 or dst/8=7) then packed_move(14 downto 12):=std_logic_vector(to_unsigned(promotion,3)); end if;
            if ROOT_ORDERING and search_active='0' and search_has_completed='1' and
               root_pv_first='0' and root_research='0' and packed_move=completed_move then valid:=false; end if;
            if k=0 or p(3)/=active_turn then
              -- Skip all 64 destinations for an ineligible source.
              dst<=63; promoting<='0'; state<=ADVANCE;
            elsif valid and search_active='1' and search_building='1' then
              packed_move:="0000"&std_logic_vector(to_unsigned(dst,6))&std_logic_vector(to_unsigned(src,6));
              if k=1 and (dst/8=0 or dst/8=7) then packed_move(14 downto 12):=std_logic_vector(to_unsigned(promotion,3)); end if;
              order_score:=512+to_integer(history_data)+square_wisdom(p,dst,false)-square_wisdom(p,src,false);
              if node_killer2(search_sp)=packed_move then order_score:=17000; end if;
              if node_killer1(search_sp)=packed_move then order_score:=18000; end if;
              if kind(t)/=0 or pawn_ep or (k=1 and (dst/8=0 or dst/8=7)) then
                n:=value(t); if pawn_ep then n:=100; end if;
                order_score:=20000+n*16-value(p);
                if k=1 and (dst/8=0 or dst/8=7) then order_score:=order_score+(value(std_logic_vector(to_unsigned(promotion,4)))-100)*8; end if;
              end if;
              if node_hint_valid(search_sp)='1' and node_hint(search_sp)=packed_move then order_score:=65535; end if;
              -- Standard chess has at most 16 pieces per side, so even 16
              -- queens have fewer than 512 pseudo-legal destinations.
              assert node_count(search_sp)<SEARCH_MOVES report "Search move RAM capacity exceeded" severity failure;
              if node_count(search_sp)<SEARCH_MOVES then
                queue_request<='1'; queue_write_address<=search_sp*SEARCH_MOVES+node_count(search_sp);
                queue_write_data<=std_logic_vector(to_unsigned(order_score,16))&packed_move;
                node_count(search_sp)<=node_count(search_sp)+1;
              end if;
              state<=ADVANCE;
              if SEE_ORDERING and (kind(t)/=0 or pawn_ep) and value(p)>n and
                 enemy_a(dst)='1' and not (node_hint_valid(search_sp)='1' and node_hint(search_sp)=packed_move) then
                queue_request<='0'; node_count(search_sp)<=node_count(search_sp);
                see_move<=packed_move; see_ep<='0'; if pawn_ep then see_ep<='1'; end if;
                see_promotion<=0; if k=1 and (dst/8=0 or dst/8=7) then see_promotion<=promotion; end if;
                see_request<='1'; see_calls<=see_calls+1; state<=SEE_WAIT;
              end if;
            elsif valid then
              -- Once a legal move is known, quiet moves at a quiescent node
              -- need no speculative apply/restore cycle.
              if search_active='1' and search_sp+1>=search_iteration and node_check(search_sp)='0' and
                 node_legal(search_sp)='1' and kind(t)=0 and not pawn_ep and not (k=1 and (dst/8=0 or dst/8=7)) then
                state<=ADVANCE;
              else state<=APPLY; end if;
            else state<=ADVANCE; end if;
          when APPLY | COMMIT_MOVE=>
            temp:=b; if state=COMMIT_MOVE then temp:=base; end if; p:=moving;
            if promoting='1' then p:=active_turn&std_logic_vector(to_unsigned(promotion,3)); end if;
            temp(src):=x"0"; temp(dst):=p;
            if en_passant='1' then
              if active_turn='0' then temp(dst-8):=x"0"; else temp(dst+8):=x"0"; end if;
            end if;
            if castling='1' then
              if dst mod 8=6 then temp(dst-1):=active_turn&"100"; temp(dst+1):=x"0";
              else temp(dst+1):=active_turn&"100"; temp(dst-2):=x"0"; end if;
            end if;
            b<=temp;
            if kind(moving)=6 then trial_king<=dst; end if;
            if state=COMMIT_MOVE then
              for i in 7 downto 1 loop history(i)<=history(i-1); end loop;
              history(0)<=candidate_move;
              if history_count<8 then history_count<=history_count+1; end if;
              n:=nonpawn_count;
              if kind(captured)>=2 and kind(captured)<=5 then n:=n-1; end if;
              if promoting='1' then n:=n+1; end if;
              nonpawn_count<=n;
              base<=temp; turn<=not turn; done<='0'; legal_count<=0; generation<=generation+1; state<=IDLE;
              if kind(moving)=6 then
                if active_turn='0' then wk<=dst; else bk<=dst; end if;
              end if;
              new_rights:=rights;
              if src=4 then new_rights(1 downto 0):="00"; end if;
              if src=60 then new_rights(3 downto 2):="00"; end if;
              if src=0 or dst=0 then new_rights(1):='0'; end if;
              if src=7 or dst=7 then new_rights(0):='0'; end if;
              if src=56 or dst=56 then new_rights(3):='0'; end if;
              if src=63 or dst=63 then new_rights(2):='0'; end if;
              rights<=new_rights; ep<=64;
              if kind(moving)=1 and abs(dst-src)=16 then ep<=(src+dst)/2; end if;
            else state<=SETTLE; end if;
          when SETTLE=>score_field_sample<=signed(mem_field_a); state<=INSPECT;
          when INSPECT=>
            if enemy_a(trial_king)='0' then
              prom_kind:=0; if promoting='1' then prom_kind:=promotion; end if;
              delta:=move_position_delta(moving,captured,src,dst,prom_kind,en_passant,castling,
                       nonpawn_count<=4,to_integer(unsigned(policy(12))),to_integer(unsigned(policy(13))));
              if active_turn/=turn then delta:=-delta; end if;
              if search_active='1' then
                node_legal(search_sp)<='1';
                tactical:=kind(captured)/=0 or promoting='1';
                node_tactical(search_sp)<='0'; if tactical then node_tactical(search_sp)<='1'; end if;
                search_depth:=search_iteration;
                remaining_q:=0; if policy(15)(0)='1' then remaining_q:=to_integer(unsigned(policy(41))); end if;
                consider_move:=search_sp+1<search_depth or node_check(search_sp)='1' or tactical;
                -- Stand-pat cutoffs are legal only after finding an actual
                -- legal move; this preserves mate and stalemate at the horizon.
                valid:=search_sp+1>=search_depth and node_check(search_sp)='0' and
                  ((active_turn=turn and node_best(search_sp)>=node_beta(search_sp)) or
                   (active_turn/=turn and node_best(search_sp)<=node_alpha(search_sp)));
                if valid then search_result<=node_best(search_sp); state<=SEARCH_RETURN;
                elsif search_sp+1>=search_depth+remaining_q and
                      (node_check(search_sp)='0' or search_sp+1>=search_depth+remaining_q+1) then
                  search_result<=node_static(search_sp); state<=SEARCH_RETURN;
                elsif consider_move then
                  if search_sp<SEARCH_LEVELS-1 then
                    cursor_src(search_sp)<=src; cursor_dst(search_sp)<=dst;
                    cursor_promotion(search_sp)<=promotion; cursor_promoting(search_sp)<=promoting;
                    node_turn(search_sp+1)<=not active_turn;
                    node_rights(search_sp+1)<=updated_rights(active_rights,src,dst);
                    node_ep(search_sp+1)<=64;
                    if kind(moving)=1 and abs(dst-src)=16 then node_ep(search_sp+1)<=(src+dst)/2; end if;
                    node_wk(search_sp+1)<=active_wk; node_bk(search_sp+1)<=active_bk;
                    if kind(moving)=6 then
                      if active_turn='0' then node_wk(search_sp+1)<=dst; else node_bk(search_sp+1)<=dst; end if;
                    end if;
                    node_alpha(search_sp+1)<=node_alpha(search_sp); node_beta(search_sp+1)<=node_beta(search_sp);
                    search_sp<=search_sp+1; search_index<=0; state<=SEARCH_SAVE;
                  else search_result<=node_static(search_sp); state<=SEARCH_RETURN; end if;
                else search_returning<='0'; search_index<=0; state<=SEARCH_RECALL_WAIT; end if;
              else
                trial_static<=clip16(base_static+delta);
                -- Root-only recurrent and whole-board priors remain inspectable.
                score_capture<=value(captured)*to_integer(unsigned(cfg(5)))/8;
                n:=0;
                if enemy_a(dst)='1' then
                  n:=value(b(dst)); if friend_a(dst)='1' then n:=n*3/4; end if;
                end if;
                score_danger<=n*to_integer(unsigned(cfg(6)))/8;
                n:=0; if field_valid(dst)='1' then n:=to_integer(score_field_sample); end if;
                score_field<=n*to_integer(unsigned(cfg(7)))/8;
                n:=to_integer(field_rng(7 downto 0) and unsigned(cfg(0)));
                if switches(17)='1' then n:=to_integer(field_rng(7 downto 0) and unsigned(switches(7 downto 0))); end if;
                score_noise<=n; audit_trial<='1'; state<=AUDIT_RESET;
              end if;
            elsif search_active='1' then
              search_returning<='0'; search_index<=0; state<=SEARCH_RECALL_WAIT;
            else state<=RESTORE; end if;
          when SCORE_MOVE=>
            capture_part:=clip16(score_capture); safety_part:=clip16(score_safety-score_danger);
            progress_part:=score_progress; field_part:=clip16(score_field); habit:=0;
            if kind(moving)>=2 and kind(moving)<=5 then
              progress_part:=progress_part+to_integer(unsigned(cfg(10+kind(moving))));
            end if;
            if (turn='0' and black_map(src)='1') or (turn='1' and white_map(src)='1') then
              progress_part:=progress_part+to_integer(unsigned(cfg(8)));
            end if;
            if kind(moving)=1 then progress_part:=progress_part+abs(dst-src)/8*to_integer(unsigned(cfg(9))); end if;
            if kind(moving)=2 or kind(moving)=3 then
              if (turn='0' and src/8=0 and dst/8/=0) or (turn='1' and src/8=7 and dst/8/=7) then
                progress_part:=progress_part+to_integer(unsigned(policy(5)));
              elsif (turn='0' and src/8/=0 and dst/8=0) or (turn='1' and src/8/=7 and dst/8=7) then
                progress_part:=progress_part-to_integer(unsigned(policy(5)));
              end if;
            end if;
            if promoting='1' then capture_part:=clip16(capture_part+value(b(dst))-100); end if;
            if (friend_a(wk)='1' and turn='1') or (friend_a(bk)='1' and turn='0') then
              progress_part:=progress_part+to_integer(unsigned(cfg(10)));
            end if;
            if castling='1' then progress_part:=progress_part+to_integer(unsigned(policy(6))); end if;
            if kind(moving)=5 and base_minor_home>0 and nonpawn_count>8 then
              progress_part:=progress_part-to_integer(unsigned(policy(7)))*base_minor_home;
            end if;
            -- Historical moves are factual host input; all habit scoring is hardware.
            if kind(captured)=0 and promoting='0' then
              for i in 0 to 3 loop
                if i*2+1<history_count then
                  if history(i*2+1)(5 downto 0)=std_logic_vector(to_unsigned(dst,6)) and
                     history(i*2+1)(11 downto 6)=std_logic_vector(to_unsigned(src,6)) then
                    habit:=habit-to_integer(unsigned(policy(3)))/(i+1);
                  end if;
                  if history(i*2+1)(11 downto 0)=candidate_move(11 downto 0) then
                    habit:=habit-to_integer(unsigned(policy(4)))/(i+1);
                  end if;
                end if;
              end loop;
            end if;
            if in_check='1' then habit:=habit/4; end if;
            progress_part:=clip16(progress_part); habit:=clip16(habit);
            if unsigned(policy(10))>=2 then
              -- Search dominates material decisions; the old spatial circuit
              -- supplies bounded root preferences, not a second search engine.
              capture_part:=capture_part/32; safety_part:=safety_part/32;
              progress_part:=progress_part/8; field_part:=field_part/8; habit:=habit/4;
              search_parts<=std_logic_vector(to_signed(capture_part,16))&std_logic_vector(to_signed(safety_part,16))&
                std_logic_vector(to_signed(progress_part,16))&std_logic_vector(to_signed(field_part,16))&
                std_logic_vector(to_signed(habit,16))&std_logic_vector(to_signed(score_noise/4,16));
              search_root_move<=candidate_move; search_active<='1'; search_sp<=0; search_index<=0;
              node_static(0)<=trial_static; if trial_static>25000 then node_static(0)<=25000; elsif trial_static< -25000 then node_static(0)<=-25000; end if; node_turn(0)<=not turn;
              node_rights(0)<=updated_rights(rights,src,dst); node_ep(0)<=64;
              if kind(moving)=1 and abs(dst-src)=16 then node_ep(0)<=(src+dst)/2; end if;
              node_wk(0)<=wk; node_bk(0)<=bk;
              if kind(moving)=6 then
                if turn='0' then node_wk(0)<=dst; else node_bk(0)<=dst; end if;
              end if;
              node_alpha(0)<=-30000; node_beta(0)<=30000; root_window_alpha<=-30000; root_scout<='0';
              if ROOT_PVS and legal_count>0 and root_research='0' then
                node_alpha(0)<=root_alpha; node_beta(0)<=root_alpha+1; root_window_alpha<=root_alpha; root_scout<='1';
              end if;
              root_research<='0'; state<=SEARCH_SAVE;
            else
              search_parts<=std_logic_vector(to_signed(capture_part,16))&std_logic_vector(to_signed(safety_part,16))&
                std_logic_vector(to_signed(progress_part,16))&std_logic_vector(to_signed(field_part,16))&
                std_logic_vector(to_signed(habit,16))&std_logic_vector(to_signed(score_noise,16));
              search_root_move<=candidate_move; search_delta_score<=0; state<=SEARCH_SUM;
              root_pv<=candidate_move & std_logic_vector(to_unsigned(0,PV_BITS-16)); root_pv_length<=1; root_bound<=0;
            end if;
          when SEARCH_SAVE=>
            w_p:=eval_white_pawns; b_p:=eval_black_pawns; w_r:=eval_white_rooks; b_r:=eval_black_rooks;
            w_min:=eval_white_min; b_min:=eval_black_min; w_max:=eval_white_max; b_max:=eval_black_max;
            wb:=eval_white_bishops; bb:=eval_black_bishops; minors:=eval_minors; knights:=eval_knights;
            bishop_colors:=eval_bishop_colors; heavy:=eval_heavy; phase_sum:=eval_phase; king_sum:=eval_king;
            next_hash:=search_hash_acc;
            if search_index=0 then
              eval_pawn_valid<="00";
              eval_mg<=0; eval_eg<=0; phase_sum:=0; king_sum:=0; eval_mob_total<=0;
              w_p:=(others=>0); b_p:=(others=>0); w_r:=(others=>0); b_r:=(others=>0);
              w_min:=(others=>7); b_min:=(others=>7); w_max:=(others=>0); b_max:=(others=>0);
              wb:=0; bb:=0; minors:=0; knights:=0; heavy:='0'; bishop_colors:="00";
              next_hash:=position_salt(active_turn,active_rights,active_ep);
              pv_request<='1'; pv_write_address<=search_sp; pv_write_data<=(others=>'0');
              if search_sp+1>max_tactical_depth then max_tactical_depth<=search_sp+1; end if;
            end if;
            for lane in 0 to 3 loop
              mg:=0; eg:=0;
              if lane<EVAL_LANES then
                n:=search_index+lane; p:=b(n); k:=kind(p); file_index:=n mod 8;
                mg:=value(p); if k=6 then mg:=0; end if;
                mg:=mg*to_integer(unsigned(policy(12)))/16;
                eg:=mg+square_wisdom(p,n,true)*to_integer(unsigned(policy(13)))/16;
                mg:=mg+square_wisdom(p,n,false)*to_integer(unsigned(policy(13)))/16;
                if p(3)='1' then mg:=-mg; eg:=-eg; end if;
                if k=1 then
                  if p(3)='0' and abs(file_index-active_wk mod 8)<=1 and
                     (n/8=active_wk/8+1 or n/8=active_wk/8+2) then mg:=mg+10; end if;
                  if p(3)='1' and abs(file_index-active_bk mod 8)<=1 and
                     (n/8=active_bk/8-1 or n/8=active_bk/8-2) then mg:=mg-10; end if;
                end if;
                if POSITION_TERMS then
                  if black_a(n)='1' and abs(file_index-active_wk mod 8)<=1 and abs(n/8-active_wk/8)<=1 then king_sum:=king_sum-6; end if;
                  if white_a(n)='1' and abs(file_index-active_bk mod 8)<=1 and abs(n/8-active_bk/8)<=1 then king_sum:=king_sum+6; end if;
                end if;
                if EVAL_LANES=1 then next_hash:=next_hash xor hash_data;
                else next_hash:=next_hash xor hash_keys(lane); end if;
                if k=2 or k=3 then phase_sum:=phase_sum+1;
                elsif k=4 then phase_sum:=phase_sum+2; elsif k=5 then phase_sum:=phase_sum+4; end if;
                if k=1 or k=4 or k=5 then heavy:='1'; end if;
                if k=2 or k=3 then
                  minors:=minors+1;
                  if k=2 then knights:=knights+1; else bishop_colors((n/8+file_index) mod 2):='1'; end if;
                end if;
                if k=1 then
                  if p(3)='0' then
                    w_p(file_index):=w_p(file_index)+1;
                    if n/8<w_min(file_index) then w_min(file_index):=n/8; end if;
                    if n/8>w_max(file_index) then w_max(file_index):=n/8; end if;
                  else
                    b_p(file_index):=b_p(file_index)+1;
                    if n/8<b_min(file_index) then b_min(file_index):=n/8; end if;
                    if n/8>b_max(file_index) then b_max(file_index):=n/8; end if;
                  end if;
                elsif k=3 then
                  if p(3)='0' then wb:=wb+1; else bb:=bb+1; end if;
                elsif k=4 then
                  if p(3)='0' then w_r(file_index):=w_r(file_index)+1; else b_r(file_index):=b_r(file_index)+1; end if;
                end if;
              end if;
              eval_lane_mg(lane)<=mg; eval_lane_eg(lane)<=eg;
            end loop;
            eval_white_pawns<=w_p; eval_black_pawns<=b_p; eval_white_rooks<=w_r; eval_black_rooks<=b_r;
            eval_white_min<=w_min; eval_black_min<=b_min; eval_white_max<=w_max; eval_black_max<=b_max;
            eval_white_bishops<=wb; eval_black_bishops<=bb; eval_minors<=minors; eval_knights<=knights;
            eval_heavy<=heavy; eval_bishop_colors<=bishop_colors; eval_phase<=phase_sum; eval_king<=king_sum;
            search_hash_acc<=next_hash; eval_pipe_valid(0)<='1';
            if search_index=64-EVAL_LANES then node_hash(search_sp)<=next_hash; state<=EVAL_DRAIN;
            else search_index<=search_index+EVAL_LANES; end if;
          when EVAL_DRAIN=>
            if eval_pipe_valid="00" then eval_file<=0; state<=EVAL_PAWNS; end if;
          when EVAL_MOBILITY=>
            mob_map:=reach;
            for i in 0 to 63 loop
              if kind(b(i))/=0 and b(i)(3)=b(eval_mob_index)(3) then mob_map(i):='0'; end if;
              -- Pawns contribute control to king pressure, not slider mobility.
            end loop;
            n:=popcount64(mob_map); k:=kind(b(eval_mob_index));
            if k=2 or k=3 then n:=n*4; elsif k=4 then n:=n*2; end if;
            if b(eval_mob_index)(3)='1' then n:=-n; end if;
            eval_mob_total<=eval_mob_total+n;
            next_mob:=64;
            for i in 63 downto 0 loop
              if i>eval_mob_index and kind(b(i))>=2 and kind(b(i))<=5 then next_mob:=i; end if;
            end loop;
            if next_mob=64 then state<=EVAL_BLEND; else eval_mob_index<=next_mob; end if;
          when EVAL_PAWNS=>
            -- Independent raw file terms feed registered weighting and sum
            -- stages. Rounding still occurs per file before accumulation.
            for lane in 0 to PAWN_LANES-1 loop
              n:=eval_file+lane; mg:=0; eg:=0; white_bonus:=0; black_bonus:=0;
              white_passed:=eval_white_pawns(n)>0; black_passed:=eval_black_pawns(n)>0;
              if eval_black_pawns(n)>0 and eval_black_max(n)>eval_white_max(n) then white_passed:=false; end if;
              if eval_white_pawns(n)>0 and eval_white_min(n)<eval_black_min(n) then black_passed:=false; end if;
              if n>0 then
                white_bonus:=white_bonus+eval_white_pawns(n-1); black_bonus:=black_bonus+eval_black_pawns(n-1);
                if eval_black_pawns(n-1)>0 and eval_black_max(n-1)>eval_white_max(n) then white_passed:=false; end if;
                if eval_white_pawns(n-1)>0 and eval_white_min(n-1)<eval_black_min(n) then black_passed:=false; end if;
              end if;
              if n<7 then
                white_bonus:=white_bonus+eval_white_pawns(n+1); black_bonus:=black_bonus+eval_black_pawns(n+1);
                if eval_black_pawns(n+1)>0 and eval_black_max(n+1)>eval_white_max(n) then white_passed:=false; end if;
                if eval_white_pawns(n+1)>0 and eval_white_min(n+1)<eval_black_min(n) then black_passed:=false; end if;
              end if;
              if white_bonus=0 then mg:=mg-eval_white_pawns(n)*12; eg:=eg-eval_white_pawns(n)*18; end if;
              if black_bonus=0 then mg:=mg+eval_black_pawns(n)*12; eg:=eg+eval_black_pawns(n)*18; end if;
              if eval_white_pawns(n)>1 then mg:=mg-(eval_white_pawns(n)-1)*14; eg:=eg-(eval_white_pawns(n)-1)*20; end if;
              if eval_black_pawns(n)>1 then mg:=mg+(eval_black_pawns(n)-1)*14; eg:=eg+(eval_black_pawns(n)-1)*20; end if;
              if white_passed then k:=eval_white_max(n); mg:=mg+k*k*3; eg:=eg+k*k*8; end if;
              if black_passed then k:=7-eval_black_min(n); mg:=mg-k*k*3; eg:=eg-k*k*8; end if;
              if eval_white_pawns(n)=0 then
                mg:=mg+eval_white_rooks(n)*14;
                if abs(n-active_wk mod 8)<=1 then mg:=mg-12; end if;
              end if;
              if eval_black_pawns(n)=0 then
                mg:=mg-eval_black_rooks(n)*14;
                if abs(n-active_bk mod 8)<=1 then mg:=mg+12; end if;
              end if;
              if eval_white_pawns(n)=0 and eval_black_pawns(n)=0 then mg:=mg+(eval_white_rooks(n)-eval_black_rooks(n))*12; end if;
              if n=0 then
                if eval_white_bishops>=2 then mg:=mg+28; eg:=eg+40; end if;
                if eval_black_bishops>=2 then mg:=mg-28; eg:=eg-40; end if;
              end if;
              eval_pawn_mg(lane)<=mg; eval_pawn_eg(lane)<=eg;
              end loop;
            eval_pawn_valid(0)<='1';
            if eval_file=8-PAWN_LANES then state<=EVAL_PAWN_DRAIN;
            else eval_file<=eval_file+PAWN_LANES; end if;
          when EVAL_PAWN_DRAIN=>
            if eval_pawn_valid="10" then
              state<=EVAL_BLEND; next_mob:=64;
              for i in 63 downto 0 loop
                if kind(b(i))>=2 and kind(b(i))<=5 then next_mob:=i; end if;
              end loop;
              if POSITION_TERMS and unsigned(policy(44))/=0 and next_mob<64 then eval_mob_index<=next_mob; state<=EVAL_MOBILITY; end if;
            end if;
          when EVAL_BLEND=>
            ph:=eval_phase; if ph>24 then ph:=24; end if;
            mg:=eval_mob_total*to_integer(unsigned(policy(44)))/16;
            eg:=eval_king*to_integer(unsigned(policy(43)))/16;
            eval_blend_mg<=(eval_mg+mg+eg)*ph; eval_blend_eg<=(eval_eg+mg/2)*(24-ph); state<=EVAL_REDUCE;
            if search_sp=0 then
              if turn='0' then root_static_mobility<=mg; root_static_king<=eg;
              else root_static_mobility<=-mg; root_static_king<=-eg; end if;
            end if;
          when EVAL_REDUCE=>
            -- Divide the magnitude by eight, then by three. Truncation toward
            -- zero is preserved for negative scores, including the signed minimum.
            blend_sum:=to_signed(eval_blend_mg+eval_blend_eg,24);
            eval_negative<=blend_sum(23); blend_magnitude:=unsigned(blend_sum);
            if blend_sum(23)='1' then blend_magnitude:=unsigned(-blend_sum); end if;
            eval_dividend<=blend_magnitude(23 downto 3); state<=EVAL_DIVIDE;
          when EVAL_DIVIDE=>
            eval_div_product<=third_product(eval_dividend); state<=EVAL_DONE;
          when EVAL_DONE=>
            score:=to_integer(eval_div_product(40 downto 21));
            if eval_negative='1' then score:=-score; end if;
            if turn='1' then score:=-score; end if;
            if score>25000 then score:=25000; elsif score< -25000 then score:=-25000; end if;
            node_draw(search_sp)<='0';
            if eval_heavy='0' and (eval_minors<=1 or (eval_knights=0 and eval_bishop_colors/="11")) then
              node_draw(search_sp)<='1'; score:=0;
            end if;
            node_static(search_sp)<=score; state<=SEARCH_BEGIN;
          when SEARCH_BEGIN=>
            node_cache_word<=cache_data;
            search_nodes<=search_nodes+1; node_legal(search_sp)<='0'; node_check(search_sp)<=enemy_a(own_king);
            node_count(search_sp)<=0; node_hint_valid(search_sp)<='0'; node_cached(search_sp)<='0'; node_repetition(search_sp)<='0';
            node_best_move(search_sp)<=(others=>'0');
            node_start_alpha(search_sp)<=node_alpha(search_sp); node_start_beta(search_sp)<=node_beta(search_sp);
            node_best(search_sp)<=30000;
            if active_turn=turn then node_best(search_sp)<=-30000; end if;
            -- At the quiescent frontier allow standing pat only out of check.
            if search_sp+1>=search_iteration and enemy_a(own_king)='0' then
              node_best(search_sp)<=node_static(search_sp);
              if active_turn=turn and node_static(search_sp)>node_alpha(search_sp) then node_alpha(search_sp)<=node_static(search_sp); end if;
              if active_turn/=turn and node_static(search_sp)<node_beta(search_sp) then node_beta(search_sp)<=node_static(search_sp); end if;
            end if;
            state<=CACHE_PROBE;
          when CACHE_PROBE=>
            repeated:=false;
            for i in 0 to SEARCH_LEVELS-1 loop
              if i<search_sp and node_hash(i)=node_hash(search_sp) then repeated:=true; end if;
            end loop;
            search_building<='1'; src<=0; dst<=0; promotion<=2; promoting<='0'; state<=PICK;
            remaining_depth:=search_iteration-search_sp-1; if remaining_depth<0 then remaining_depth:=0; end if;
            remaining_q:=0;
            if policy(15)(0)='1' then remaining_q:=search_iteration+to_integer(unsigned(policy(41)))-search_sp-1; end if;
            if remaining_q<0 then remaining_q:=0; elsif remaining_q>MAX_QUIESCENCE then remaining_q:=MAX_QUIESCENCE; end if;
            if node_draw(search_sp)='1' then search_result<=0; state<=SEARCH_RETURN;
            elsif repeated then
              node_repetition(search_sp)<='1'; search_result<=0; state<=SEARCH_RETURN;
            elsif policy(42)(0)='1' and node_cache_word(127)='1' and unsigned(node_cache_word(126 downto 111))=search_epoch and
                  unsigned(node_cache_word(110 downto 47))=node_hash(search_sp) then
              search_cache_hits<=search_cache_hits+1;
              node_hint(search_sp)<=node_cache_word(20 downto 5); node_hint_valid(search_sp)<='1';
              score:=to_integer(signed(node_cache_word(46 downto 31)));
              if score>27000 then score:=score-search_sp-1; elsif score< -27000 then score:=score+search_sp+1; end if;
              if unsigned(node_cache_word(30 downto 27))>=remaining_depth and unsigned(node_cache_word(26 downto 23))>=remaining_q and
                 unsigned(node_cache_word(4 downto 1))>=SEARCH_LEVELS-search_sp-1 and
                 (node_cache_word(22 downto 21)="00" or (node_cache_word(22 downto 21)="01" and score>=node_beta(search_sp)) or
                  (node_cache_word(22 downto 21)="10" and score<=node_alpha(search_sp))) then
                node_cached(search_sp)<='1'; search_result<=score; state<=SEARCH_RETURN;
                search_cache_cutoffs<=search_cache_cutoffs+1;
                if node_cache_word(20 downto 5)/=x"0000" then
                  pv_request<='1'; pv_write_address<=search_sp;
                  pv_write_data<=node_cache_word(20 downto 5)&std_logic_vector(to_unsigned(0,PV_BITS-16))&"0001";
                end if;
              end if;
            end if;
          when NODE_READY=>
            search_building<='0'; node_remaining(search_sp)<=node_count(search_sp); state<=ADVANCE;
          when MOVE_SELECT=>
            picked:=search_pick_data; picked_index:=search_pick_index;
            if QUEUE_LANES=4 then
              if search_scan=0 or unsigned(queue_top_data(31 downto 16))>unsigned(picked(31 downto 16)) then
                picked:=queue_top_data; picked_index:=queue_top_index;
              end if;
            elsif search_scan=0 or unsigned(queue_data(31 downto 16))>unsigned(picked(31 downto 16)) then
              picked:=queue_data; picked_index:=search_scan;
            end if;
            search_pick_data<=picked; search_pick_index<=picked_index;
            if search_scan+QUEUE_LANES>=node_remaining(search_sp) then
              search_scan<=node_remaining(search_sp)-1; state<=MOVE_APPLY;
            else search_scan<=search_scan+QUEUE_LANES; end if;
          when SEE_WAIT=>
            if see_done='1' then
              n:=value(b(dst)); if see_ep='1' then n:=100; end if;
              order_score:=20000+n*16-value(b(src));
              if see_result<0 then order_score:=64+n/16; end if;
              if unsigned(see_move(14 downto 12))/=0 then order_score:=order_score+6000; end if;
              queue_request<='1'; queue_write_address<=search_sp*SEARCH_MOVES+node_count(search_sp);
              queue_write_data<=std_logic_vector(to_unsigned(order_score,16))&see_move;
              node_count(search_sp)<=node_count(search_sp)+1; state<=ADVANCE;
            end if;
          when MOVE_APPLY=>
            queue_request<='1'; queue_write_address<=search_sp*SEARCH_MOVES+search_pick_index; queue_write_data<=queue_data;
            node_remaining(search_sp)<=node_remaining(search_sp)-1;
            src<=to_integer(unsigned(search_pick_data(5 downto 0))); dst<=to_integer(unsigned(search_pick_data(11 downto 6)));
            promotion<=2;
            if unsigned(search_pick_data(14 downto 12))/=0 then promotion<=to_integer(unsigned(search_pick_data(14 downto 12))); end if;
            state<=PICK;
          when SEARCH_RECALL_WAIT=>state<=SEARCH_RECALL_COPY;
          when SEARCH_RECALL_COPY=>
            for lane in 0 to STACK_LANES-1 loop
              b(search_index+lane)<=search_q(lane*4+3 downto lane*4);
            end loop;
            if search_index=64-STACK_LANES then
              if search_returning='1' then state<=SEARCH_ACCEPT;
              else state<=ADVANCE; end if;
            else search_index<=search_index+STACK_LANES; state<=SEARCH_RECALL_WAIT; end if;
          when SEARCH_ACCEPT=>
            score:=node_best(search_sp);
            if (active_turn=turn and search_result>score) or (active_turn/=turn and search_result<score) then
              n:=to_integer(unsigned(pv_q(3 downto 0)))+1; if n>SEARCH_LEVELS then n:=SEARCH_LEVELS; end if;
              pv_request<='1'; pv_write_address<=search_sp;
              pv_write_data<=candidate_move&pv_q(PV_BITS+3 downto 20)&std_logic_vector(to_unsigned(n,4));
            end if;
            if active_turn=turn then
              if search_result>score then score:=search_result; node_best_move(search_sp)<=candidate_move; end if;
              if score>node_alpha(search_sp) then node_alpha(search_sp)<=score; end if;
              valid:=score>=node_beta(search_sp);
            else
              if search_result<score then score:=search_result; node_best_move(search_sp)<=candidate_move; end if;
              if score<node_beta(search_sp) then node_beta(search_sp)<=score; end if;
              valid:=score<=node_alpha(search_sp);
            end if;
            node_best(search_sp)<=score;
            if valid then
              search_cutoffs<=search_cutoffs+1; search_result<=score; state<=SEARCH_RETURN;
              if node_tactical(search_sp)='0' then
                if node_killer1(search_sp)/=candidate_move then
                  node_killer2(search_sp)<=node_killer1(search_sp); node_killer1(search_sp)<=candidate_move;
                end if;
                n:=search_iteration-search_sp; if n<1 then n:=1; end if;
                n:=to_integer(history_data)+n*n; if n>8191 then n:=8191; end if;
                history_request<='1'; history_write_address<=src*64+dst; history_write_data<=to_unsigned(n,13);
              end if;
            else
              search_returning<='0'; search_index<=0; state<=SEARCH_RECALL_WAIT;
            end if;
          when SEARCH_RETURN=>
            search_building<='0';
            if policy(42)(0)='1' and node_cached(search_sp)='0' and node_repetition(search_sp)='0' then
              cache_word:=(others=>'0'); cache_word(127):='1';
              cache_word(126 downto 111):=std_logic_vector(search_epoch);
              cache_word(110 downto 47):=std_logic_vector(node_hash(search_sp));
              score:=search_result;
              -- Store mate distance relative to this position, not its root ply.
              if score>27000 then score:=score+search_sp+1; elsif score< -27000 then score:=score-search_sp-1; end if;
              cache_word(46 downto 31):=std_logic_vector(to_signed(score,16));
              n:=search_iteration-search_sp-1; if n<0 then n:=0; end if;
              cache_word(30 downto 27):=std_logic_vector(to_unsigned(n,4));
              n:=0; if policy(15)(0)='1' then n:=search_iteration+to_integer(unsigned(policy(41)))-search_sp-1; end if;
              if n<0 then n:=0; elsif n>MAX_QUIESCENCE then n:=MAX_QUIESCENCE; end if;
              cache_word(26 downto 23):=std_logic_vector(to_unsigned(n,4));
              if search_result<=node_start_alpha(search_sp) then cache_word(22 downto 21):="10";
              elsif search_result>=node_start_beta(search_sp) then cache_word(22 downto 21):="01"; end if;
              cache_word(20 downto 5):=node_best_move(search_sp);
              cache_word(4 downto 1):=std_logic_vector(to_unsigned(SEARCH_LEVELS-search_sp-1,4));
              cache_request<='1'; cache_write_address<=to_integer(node_hash(search_sp)(CACHE_INDEX_BITS-1 downto 0)); cache_write_data<=cache_word;
              search_cache_stores<=search_cache_stores+1;
            end if;
            if search_sp=0 then state<=SEARCH_ROOT;
            else
              if node_repetition(search_sp)='1' then node_repetition(search_sp-1)<='1'; end if;
              search_sp<=search_sp-1; search_index<=0; search_returning<='1';
              src<=cursor_src(search_sp-1); dst<=cursor_dst(search_sp-1);
              promotion<=cursor_promotion(search_sp-1); promoting<=cursor_promoting(search_sp-1);
              state<=SEARCH_RECALL_WAIT;
            end if;
          when SEARCH_ROOT=>
            if root_scout='1' and search_result>root_window_alpha then
              -- A scout can establish a lower bound, not an exact winning score.
              -- Reapply the factual root move, then re-search with a full window.
              b<=base; search_active<='0'; root_research<='1'; root_researches<=root_researches+1;
              src<=to_integer(unsigned(search_root_move(5 downto 0))); dst<=to_integer(unsigned(search_root_move(11 downto 6)));
              promotion<=2;
              if unsigned(search_root_move(14 downto 12))/=0 then promotion<=to_integer(unsigned(search_root_move(14 downto 12))); end if;
              state<=PICK;
            else
              search_parts<=(others=>'0'); search_delta_score<=search_result; root_bound<=0;
              if root_scout='1' then root_bound<=1; end if;
              root_pv<=search_root_move&pv_q(PV_BITS+3 downto 20);
              n:=to_integer(unsigned(pv_q(3 downto 0)))+1; if n>SEARCH_LEVELS then n:=SEARCH_LEVELS; end if;
              root_pv_length<=n; state<=SEARCH_SUM;
            end if;
          when SEARCH_SUM=>
            -- A balanced, registered adder tree is shared by spatial-only and
            -- search modes. It prevents area sharing from building a long
            -- native-RX-to-score combinational path through serial adders.
            search_sum_a<=to_integer(signed(search_parts(95 downto 80)))+to_integer(signed(search_parts(79 downto 64)));
            search_sum_b<=to_integer(signed(search_parts(63 downto 48)))+to_integer(signed(search_parts(47 downto 32)));
            search_sum_c<=to_integer(signed(search_parts(31 downto 16)))+to_integer(signed(search_parts(15 downto 0)));
            state<=SEARCH_ADD;
          when SEARCH_ADD=>
            search_sum_a<=search_sum_a+search_delta_score; search_sum_b<=search_sum_b+search_sum_c;
            state<=SEARCH_SCORE;
          when SEARCH_SCORE=>
            total:=search_sum_a+search_sum_b;
            score:=clip16(total);
            -- synthesis translate_off
            if TRACE_SEARCH then
              report "search root "&integer'image(to_integer(unsigned(search_root_move)))&
                     " activation "&integer'image(score)&" nodes "&integer'image(to_integer(search_nodes));
            end if;
            -- synthesis translate_on
            if legal_count<256 then
              candidate_request<='1'; candidate_write_index<=candidate_bank*256+legal_count;
              candidate_write_data<=search_root_move&std_logic_vector(to_signed(score,16))&search_parts&std_logic_vector(to_signed(search_delta_score,16));
              legal_count<=legal_count+1;
            end if;
            if root_bound=0 and score>best_score then
              best_score<=score; best_move<=search_root_move;
              iteration_pv<=root_pv; iteration_pv_length<=root_pv_length;
              chosen_static_king<=root_static_king; chosen_static_mobility<=root_static_mobility;
            end if;
            if search_iteration>=2 and root_bound=0 and score>root_alpha then root_alpha<=score; end if;
            src<=to_integer(unsigned(search_root_move(5 downto 0))); dst<=to_integer(unsigned(search_root_move(11 downto 6)));
            promoting<='0'; promotion<=2;
            if unsigned(search_root_move(14 downto 12))/=0 then
              promoting<='1'; promotion<=to_integer(unsigned(search_root_move(14 downto 12)));
            end if;
            search_active<='0'; b<=base; state<=ADVANCE;
            if root_pv_first='1' then
              root_pv_first<='0'; src<=0; dst<=0; promotion<=2; promoting<='0'; state<=PICK;
            end if;
          when RESTORE=>b<=base; state<=ADVANCE;
          when ADVANCE=>
            if search_active='1' and search_building='0' then
              if node_remaining(search_sp)=0 then
                score:=node_best(search_sp);
                if node_legal(search_sp)='0' then
                  score:=0;
                  if node_check(search_sp)='1' then
                    score:=28000-(search_sp+1); if active_turn=turn then score:=-score; end if;
                  end if;
                end if;
                search_result<=score; state<=SEARCH_RETURN;
              else
                search_scan<=0; search_pick_index<=0; search_pick_data<=(others=>'0'); state<=MOVE_SELECT;
              end if;
            elsif promoting='1' and promotion<5 then promotion<=promotion+1; state<=PICK;
            else
              promotion<=2;
              next_destination:=64;
              if FAST_DESTINATIONS then
                -- The wired spatial plane already knows which destinations
                -- this source can reach. Walk its set bits in square order
                -- instead of spending PICK/ADVANCE cycles on every square.
                -- Pawn pushes and castling are absent from the attack plane;
                -- include a superset here and retain all checks in PICK.
                destination_mask:=reach;
                if kind(b(src))=1 then
                  if active_turn='0' then
                    if src<56 then destination_mask(src+8):='1'; end if;
                    if src/8=1 then destination_mask(src+16):='1'; end if;
                  else
                    if src>=8 then destination_mask(src-8):='1'; end if;
                    if src/8=6 then destination_mask(src-16):='1'; end if;
                  end if;
                elsif kind(b(src))=6 then
                  if src=4 then destination_mask(2):='1'; destination_mask(6):='1'; end if;
                  if src=60 then destination_mask(58):='1'; destination_mask(62):='1'; end if;
                end if;
                for i in 63 downto 0 loop
                  if i>dst and destination_mask(i)='1' then next_destination:=i; end if;
                end loop;
              elsif dst<63 then next_destination:=dst+1;
              end if;
              if next_destination=64 then
                dst<=0;
                -- All 64 source eligibility bits are decoded concurrently.
                -- Pick the next occupied friendly square rather than visiting
                -- each empty/enemy square through two controller states.
                next_source:=64;
                if FAST_SOURCES then
                  for i in 63 downto 0 loop
                    if i>src and source_available(i)='1' then next_source:=i; end if;
                  end loop;
                elsif src<63 then next_source:=src+1;
                end if;
                if next_source=64 then
                  if search_active='1' then state<=NODE_READY; else state<=FINISH; end if;
                else src<=next_source; state<=PICK; end if;
              else dst<=next_destination; state<=PICK; end if;
            end if;
          when FINISH=>
            published_bank<=candidate_bank; completed_count<=legal_count; completed_move<=best_move; completed_score<=best_score;
            search_completed<=search_iteration; search_has_completed<='1'; b<=base;
            completed_pv<=iteration_pv; completed_pv_length<=iteration_pv_length;
            completed_static_king<=chosen_static_king; completed_static_mobility<=chosen_static_mobility;
            if legal_count>0 and search_iteration>=2 and search_iteration<to_integer(unsigned(policy(10))) and
               (search_limit=0 or elapsed<search_limit) then
              candidate_bank<=1-candidate_bank; search_iteration<=search_iteration+1;
              legal_count<=0; best_move<=(others=>'0'); best_score<=-32768;
              src<=0; dst<=0; promotion<=2; promoting<='0'; search_active<='0'; state<=PICK;
              root_alpha<=-30000; iteration_pv_length<=0;
              if ROOT_ORDERING then
                root_pv_first<='1'; src<=to_integer(unsigned(best_move(5 downto 0))); dst<=to_integer(unsigned(best_move(11 downto 6)));
                if unsigned(best_move(14 downto 12))/=0 then promotion<=to_integer(unsigned(best_move(14 downto 12))); end if;
              end if;
            else
              done<='1'; state<=IDLE; search_running<='0';
              if legal_count>0 and search_iteration<to_integer(unsigned(policy(10))) then search_timed_out<='1'; end if;
            end if;
        end case;

        -- A completed iteration has its own candidate RAM bank. Budget expiry
        -- discards the partial next iteration and publishes only that full set.
        if search_running='1' and search_has_completed='1' and search_limit/=0 and elapsed>=search_limit and state/=FINISH then
          search_active<='0'; search_building<='0'; search_running<='0'; search_timed_out<='1';
          state<=IDLE; b<=base; done<='1';
          legal_count<=completed_count; best_move<=completed_move; best_score<=completed_score;
          chosen_static_king<=completed_static_king; chosen_static_mobility<=completed_static_mobility;
        end if;

        if keys(2)='1' and old_keys(2)='0' and state/=LOAD_SCAN and state/=LOAD_FINISH and state/=BOOT_POLICY and state/=LOAD_POLICY and state/=LOAD_ROUTES then
          search_active<='0'; search_running<='0'; state<=IDLE; base<=initial_board; b<=initial_board; turn<='0'; rights<="1111"; ep<=64;
          wk<=4; bk<=60; done<='0'; legal_count<=0; field_valid<=(others=>'0'); field_leds<=(others=>'0'); generation<=generation+1; history_count<=0; nonpawn_count<=14;
        end if;
        if command_pending='1' then
          command_pending<='0';
          sub:=to_integer(unsigned(packet_rx(0))); len:=packet_length;
          response_request<='1'; response_status_i<=0; response_length<=1; response_kind<=1; ack<=x"00";
          mutating:=sub=1 or sub=2 or sub=3 or sub=8 or sub=9 or sub=10 or sub=11 or sub=13 or sub=17;
          duplicate:=mutating and have_token='1' and packet_token=last_token;
          if duplicate then response_status_i<=cached_status;
          else
            if mutating then last_token<=packet_token; have_token<='1'; cached_status<=0; end if;
            case sub is
              when 0=>
                if len/=1 then response_status_i<=1;
                else response_kind<=0; response_length<=40; status_cycles<=elapsed; end if;
              when 1=>
                if len/=68 or state/=IDLE or unsigned(packet_rx(65))>1 or
                   unsigned(packet_rx(66))>15 or unsigned(packet_rx(67))>64 then
                  response_status_i<=3; cached_status<=3;
                else
                  load_index<=0; load_white_kings<=0; load_black_kings<=0; load_invalid<='0';
                  load_nonpawn<=0;
                  state<=LOAD_SCAN; response_request<='0';
                end if;
              when 2=>
                if len/=1 or state/=IDLE then response_status_i<=3; cached_status<=3;
                else state<=SNAPSHOT; done<='0'; end if;
              when 3=>
                if len/=1 then response_status_i<=1; cached_status<=1;
                elsif state=BOOT_POLICY then response_status_i<=3; cached_status<=3;
                else search_active<='0'; search_running<='0'; state<=IDLE; b<=base; done<='0'; end if;
              when 4=>
                if len/=1 then response_status_i<=1;
                else response_kind<=4; response_length<=80; end if;
              when 5=>
                if len/=1 then response_status_i<=1;
                else response_kind<=5; response_length<=67; end if;
              when 6=>
                if len/=1 then response_status_i<=1;
                else response_kind<=6; response_length<=80; end if;
              when 7=>
                if len/=2 or unsigned(packet_rx(1))>15 then response_status_i<=3;
                else page<=to_integer(unsigned(packet_rx(1))); response_kind<=7; response_length<=64; end if;
              when 8=>
                if len/=81 or state/=IDLE then response_status_i<=3; cached_status<=3;
                else
                  for i in 0 to 15 loop cfg(i)<=packet_rx(i+1); end loop;
                  route_index<=0; state<=LOAD_ROUTES; response_request<='0'; done<='0';
                end if;
              when 9=>
                if len/=5 then response_status_i<=1; cached_status<=1;
                else
                  seed32:=unsigned(std_logic_vector'(packet_rx(1)&packet_rx(2)&packet_rx(3)&packet_rx(4)));
                  if seed32=0 then seed32:=x"D0E2C35F"; end if;
                  rng<=seed32;
                  field_rng<=advance_rng(seed32,CLOCK_DIVIDE-1);
                end if;
              when 10=>
                if len/=1 then response_status_i<=1; cached_status<=1;
                elsif policy_initialized='0' then response_status_i<=3; cached_status<=3;
                else
                  search_active<='0'; search_running<='0'; state<=IDLE; base<=initial_board; b<=initial_board; turn<='0'; rights<="1111"; ep<=64;
                  wk<=4; bk<=60; done<='0'; legal_count<=0; field_valid<=(others=>'0'); field_leds<=(others=>'0'); generation<=generation+1; history_count<=0; nonpawn_count<=14;
                end if;
              when 11=>
                -- Commit only the exact hardware-selected move, with generation
                -- guard. This cannot bypass the legality filter or replay a ply.
                if len/=7 or state/=IDLE or done='0' or legal_count=0 or
                   unsigned(std_logic_vector'(packet_rx(1)&packet_rx(2)&packet_rx(3)&packet_rx(4)))/=generation or
                   std_logic_vector'(packet_rx(5)&packet_rx(6))/=best_move then
                  response_status_i<=3; cached_status<=3;
                else
                  src<=to_integer(unsigned(best_move(5 downto 0)));
                  dst<=to_integer(unsigned(best_move(11 downto 6)));
                  n:=to_integer(unsigned(best_move(14 downto 12)));
                  promoting<='0'; if n>=2 and n<=5 then promotion<=n; promoting<='1'; end if;
                  k:=to_integer(unsigned(best_move(5 downto 0)));
                  x:=to_integer(unsigned(best_move(11 downto 6)));
                  moving<=base(k); captured<=base(x); en_passant<='0'; castling<='0';
                  if kind(base(k))=1 and x=ep and kind(base(x))=0 then en_passant<='1'; end if;
                  if kind(base(k))=6 and abs(x-k)=2 then castling<='1'; end if;
                  state<=COMMIT_MOVE;
                end if;
              when 12=>
                if len/=2 or unsigned(packet_rx(1))>1 or state/=IDLE then response_status_i<=3;
                else policy_page<=to_integer(unsigned(packet_rx(1))); response_kind<=12; response_length<=64; end if;
              when 13=>
                if len/=66 or state/=IDLE or unsigned(packet_rx(1))>1 then response_status_i<=3; cached_status<=3;
                elsif packet_rx(1)=x"00" and (unsigned(packet_rx(12))=1 or unsigned(packet_rx(12))>MAX_SEARCH_DEPTH or unsigned(packet_rx(14))>32 or unsigned(packet_rx(15))>32 or unsigned(packet_rx(17))>1 or
                      unsigned(packet_rx(42))>60 or unsigned(packet_rx(43))>MAX_QUIESCENCE or unsigned(packet_rx(44))>1 or
                      unsigned(packet_rx(45))>32 or unsigned(packet_rx(46))>32) then
                  response_status_i<=3; cached_status<=3;
                else
                  policy_page<=to_integer(unsigned(packet_rx(1)(0 downto 0))); policy_index<=0;
                  state<=LOAD_POLICY; response_request<='0'; done<='0';
                end if;
              when 18=>
                if len=1 then
                  response_kind<=18; response_length<=128; stats_snapshot<=(others=>x"00");
                  for j in 0 to 3 loop
                    stats_snapshot(j)<=std_logic_vector(search_nodes(31-j*8 downto 24-j*8));
                    stats_snapshot(4+j)<=std_logic_vector(search_cutoffs(31-j*8 downto 24-j*8));
                    stats_snapshot(12+j)<=std_logic_vector(search_cache_hits(31-j*8 downto 24-j*8));
                    stats_snapshot(16+j)<=std_logic_vector(search_cache_stores(31-j*8 downto 24-j*8));
                    stats_word:=to_unsigned(CLOCK_HZ,32); stats_snapshot(20+j)<=std_logic_vector(stats_word(31-j*8 downto 24-j*8));
                    stats_snapshot(28+j)<=std_logic_vector(search_cache_cutoffs(31-j*8 downto 24-j*8));
                    stats_snapshot(32+j)<=std_logic_vector(root_researches(31-j*8 downto 24-j*8));
                    stats_snapshot(98+j)<=std_logic_vector(elapsed(31-j*8 downto 24-j*8));
                    stats_snapshot(102+j)<=std_logic_vector(see_calls(31-j*8 downto 24-j*8));
                    stats_snapshot(106+j)<=std_logic_vector(see_cycles(31-j*8 downto 24-j*8));
                    for g in 0 to 6 loop stats_snapshot(36+g*4+j)<=std_logic_vector(phase_counters(g)(31-j*8 downto 24-j*8)); end loop;
                  end loop;
                  stats_snapshot(8)<=policy(10); if policy(15)(0)='1' then stats_snapshot(9)<=policy(41); end if;
                  stats_snapshot(10)<=oct(search_completed); stats_snapshot(11)<="000000"&policy(42)(0)&search_timed_out;
                  stats_snapshot(24)<=oct(MAX_SEARCH_DEPTH); stats_snapshot(25)<=oct(max_tactical_depth);
                  stats_snapshot(26)<=oct(EVAL_LANES); stats_snapshot(27)<=oct(CLOCK_DIVIDE);
                  stats_snapshot(110)<=std_logic_vector(elapsed(47 downto 40)); stats_snapshot(111)<=std_logic_vector(elapsed(39 downto 32));
                  for g in 0 to 6 loop
                    stats_snapshot(112+g*2)<=std_logic_vector(phase_counters(g)(47 downto 40));
                    stats_snapshot(113+g*2)<=std_logic_vector(phase_counters(g)(39 downto 32));
                  end loop;
                  stats_snapshot(126)<=oct(QUEUE_LANES);
                  stats_snapshot(64)<=oct(completed_pv_length);
                  for j in 0 to SEARCH_LEVELS*2-1 loop stats_snapshot(65+j)<=completed_pv(PV_BITS-1-j*8 downto PV_BITS-8-j*8); end loop;
                  if POSITION_TERMS then stats_snapshot(93)(0)<='1'; end if;
                  if ROOT_PVS then stats_snapshot(93)(1)<='1'; end if;
                  if ROOT_ORDERING then stats_snapshot(93)(2)<='1'; end if;
                  if SEE_ORDERING then stats_snapshot(93)(3)<='1'; end if;
                  stats_snapshot(94)<=oct(completed_static_king/256); stats_snapshot(95)<=oct(completed_static_king);
                  stats_snapshot(96)<=oct(completed_static_mobility/256); stats_snapshot(97)<=oct(completed_static_mobility);
                  stats_word:=unsigned(std_logic_vector(to_signed(completed_static_king,32)));
                  stats_snapshot(94)<=std_logic_vector(stats_word(15 downto 8));
                  stats_word:=unsigned(std_logic_vector(to_signed(completed_static_mobility,32)));
                  stats_snapshot(96)<=std_logic_vector(stats_word(15 downto 8));
                else response_status_i<=1; end if;
              when 19=>
                if len/=2 or unsigned(packet_rx(1))>15 then response_status_i<=3;
                else page<=to_integer(unsigned(packet_rx(1))); response_kind<=19; response_length<=16; end if;
              when 14=>
                if len/=2 or unsigned(packet_rx(1))>63 then response_status_i<=3;
                else page<=to_integer(unsigned(packet_rx(1))); response_kind<=14; response_length<=72; end if;
              when 17=>
                if len<2 or state/=IDLE or unsigned(packet_rx(1))>8 then response_status_i<=3; cached_status<=3;
                elsif len/=2+to_integer(unsigned(packet_rx(1)))*2 then response_status_i<=1; cached_status<=1;
                else
                  history_count<=to_integer(unsigned(packet_rx(1)));
                  for i in 0 to 7 loop history(i)<=packet_rx(2+i*2)&packet_rx(3+i*2); end loop;
                  done<='0';
                end if;
              when others=>response_status_i<=2;
            end case;
          end if;
        end if;
      end if;
    end if;
  end process;
end architecture;

