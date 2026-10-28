library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.chess_pkg.all;

entity tb_chess_engine is
  generic(VECTOR_FILE : string := "sim/chess_vectors.txt"; CLOCK_DIVIDE : positive := 4; SEARCH_DEPTH : natural := 0;
    CACHE_ENABLE : natural := 1; QUIESCENCE : natural := 4; BUDGET_SECONDS : natural := 0;
    TEST_CLOCK_HZ : positive := 50000000; MAX_POLLS : positive := 20000; TRACE : boolean := false;
    CHECK_TACTICS : boolean := true; EXPECT_TIMEOUT : boolean := false;
    DETERMINISTIC : boolean := false; FAST_DESTINATIONS : boolean := true; STACK_LANES : positive := 8;
    FAST_SOURCES : boolean := true; PAWN_LANES : positive := 2; FIRST_POSITION : natural := 0;
    EVAL_LANES : positive := 4; ROOT_PVS : boolean := true; ROOT_ORDERING : boolean := true;
    POSITION_TERMS : boolean := true; SEE_ORDERING : boolean := true; QUEUE_LANES : positive := 4;
    EXPECT_MIN_PLY : natural := 0; REPORT_SCORES : boolean := false;
    POSITION_COUNT : natural := natural'high);
end;
architecture test of tb_chess_engine is
  signal clk : std_logic := '0';
  signal reset,rx_we,command,complete : std_logic := '0';
  signal rx_addr : natural range 0 to 80 := 0;
  signal rx_data,rd_data : byte_t := x"00";
  signal req_len : natural range 0 to 81 := 0;
  signal token : std_logic_vector(79 downto 0) := (others=>'0');
  signal status : natural range 0 to 3;
  signal resp_len : natural range 0 to 1024;
  signal rd_addr : natural range 0 to 1023 := 0;
  signal panel : std_logic_vector(31 downto 0);
  signal running : boolean := true;
begin
  clk <= not clk after 10 ns when running else '0';
  dut : entity work.chess_engine generic map(CLOCK_DIVIDE=>CLOCK_DIVIDE,TRACE_SEARCH=>TRACE,CLOCK_HZ=>TEST_CLOCK_HZ,FAST_DESTINATIONS=>FAST_DESTINATIONS,STACK_LANES=>STACK_LANES,FAST_SOURCES=>FAST_SOURCES,PAWN_LANES=>PAWN_LANES,
    EVAL_LANES=>EVAL_LANES,ROOT_PVS=>ROOT_PVS,ROOT_ORDERING=>ROOT_ORDERING,POSITION_TERMS=>POSITION_TERMS,SEE_ORDERING=>SEE_ORDERING,QUEUE_LANES=>QUEUE_LANES) port map(clk=>clk,reset=>reset,
    rx_we=>rx_we,rx_address=>rx_addr,rx_data=>rx_data,command=>command,
    request_length=>req_len,request_token=>token,response_done=>complete,
    response_status=>status,response_length=>resp_len,read_address=>rd_addr,
    read_data=>rd_data,switches=>(others=>'0'),keys=>(others=>'0'),panel=>panel);
  process
    file vectors : text open read_mode is VECTOR_FILE;
    variable line_in : line;
    variable packet : bytes_t(0 to 80);
    variable n,count,found,move,hi,lo,best,test_count,tx : natural := 0;
    type seen_t is array(0 to 32767) of boolean;
    variable seen : seen_t := (others=>false);
    type scores_t is array(0 to 32767) of integer;
    variable expected_scores : scores_t := (others=>40000);
    variable expected_kinds : scores_t := (others=>0);
    variable page_metadata : bytes_t(0 to 15);
    variable pv_text : line;
    variable activation,parts,part : integer;
    variable runtime_policy : bytes_t(0 to 127) := policy_defaults;
    variable focus_move,other_move,score_gap : integer;
    variable expected_maps : bytes_t(0 to 15);
    variable expected_position : bytes_t(0 to 66);
    variable committed_position : bytes_t(0 to 66);
    variable commit_expected : boolean;
    variable expected_best : integer;
    variable decision_cycles,nodes,cache_hits,completed_depth,search_flags : natural;
    variable profile_sum,snapshot_cycles,pv_length,meta,selected_kind : natural;
    procedure send(constant length : natural; constant expected_status : natural := 0) is
    begin
      for i in 0 to length-1 loop
        wait until falling_edge(clk); rx_we<='1'; rx_addr<=i; rx_data<=packet(i);
      end loop;
      wait until falling_edge(clk); rx_we<='0'; req_len<=length;
      tx:=tx+1; token<=std_logic_vector(to_unsigned(tx,80)); command<='1';
      for cycle in 0 to 100*CLOCK_DIVIDE loop
        wait until falling_edge(clk);
        exit when complete='1';
      end loop;
      command<='0';
      assert complete='1' report "command did not complete" severity failure;
      assert status=expected_status report "unexpected command status" severity failure;
    end;
    procedure get(constant addr : natural; variable value_out : out natural) is
    begin
      rd_addr<=addr; wait until rising_edge(clk); wait until rising_edge(clk); wait for 1 ns;
      value_out:=to_integer(unsigned(rd_data));
    end;
  begin
    reset<='1'; wait for 100 ns; wait until falling_edge(clk); reset<='0';
    wait for 20 us*CLOCK_DIVIDE;
    runtime_policy(10):=oct(SEARCH_DEPTH);
    runtime_policy(40):=oct(BUDGET_SECONDS);runtime_policy(41):=oct(QUIESCENCE);runtime_policy(42):=oct(CACHE_ENABLE);
    packet(0):=x"0D"; packet(1):=x"00";
    for i in 0 to 63 loop packet(i+2):=runtime_policy(i); end loop;
    send(66);
    if DETERMINISTIC then
      packet(0):=x"06";send(1);
      for i in 0 to 79 loop get(i,n);packet(i+1):=oct(n);end loop;
      packet(0):=x"08";packet(1):=x"00";packet(5):=x"00";packet(8):=x"00";send(81);
    end if;
    for i in 1 to FIRST_POSITION loop readline(vectors,line_in);end loop;
    test_count:=FIRST_POSITION;
    while not endfile(vectors) and test_count-FIRST_POSITION<POSITION_COUNT loop
      readline(vectors,line_in);
      packet(0):=x"01";
      for i in 1 to 67 loop read(line_in,n); packet(i):=oct(n); expected_position(i-1):=oct(n); end loop;
      read(line_in,count); seen:=(others=>false); expected_scores:=(others=>40000);
      for i in 1 to count loop read(line_in,n); seen(n):=true; end loop;
      for i in 0 to 15 loop read(line_in,n); expected_maps(i):=oct(n); end loop;
      focus_move:=-1; other_move:=-1; score_gap:=0;
      if line_in.all'length>0 then read(line_in,focus_move); read(line_in,other_move); read(line_in,score_gap); end if;
      expected_best:=-1;
      if line_in.all'length>0 then read(line_in,expected_best); end if;
      commit_expected:=line_in.all'length>0;
      if commit_expected then
        for i in 0 to 66 loop read(line_in,n); committed_position(i):=oct(n); end loop;
      end if;
      send(68);
      packet(0):=x"02"; send(1);
      for poll in 0 to MAX_POLLS-1 loop
        wait for 100 us*CLOCK_DIVIDE;
        packet(0):=x"00"; send(1); get(5,n);
        exit when n=1;
      end loop;
      get(5,n); assert n=1 report "evaluation timed out" severity failure;
      get(8,hi); get(9,lo); found:=hi*256+lo;
      assert found=count report "legal count mismatch at position "&integer'image(test_count)&
        ": actual "&integer'image(found)&" expected "&integer'image(count) severity failure;
      get(10,hi); get(11,lo); best:=hi*256+lo;
      if count>0 then assert seen(best) report "best move illegal" severity failure; end if;
      if CHECK_TACTICS and expected_best>=0 then assert best=expected_best report "tactical best move mismatch: actual "&integer'image(best)&" expected "&integer'image(expected_best) severity failure; end if;
      packet(0):=x"05"; send(1);
      for i in 0 to 66 loop
        get(i,n); assert oct(n)=expected_position(i) report "search corrupted factual position metadata" severity failure;
      end loop;
      if SEARCH_DEPTH>=2 and count>0 then
        packet(0):=x"00";send(1);
        get(12,hi);get(13,lo);activation:=hi*256+lo;
        if activation>=32768 then activation:=activation-65536;end if;
        packet(0):=x"12"; send(1); get(0,hi); get(1,lo); get(2,n); get(3,found);
        nodes:=hi*16777216+lo*65536+n*256+found;
        assert hi+lo+n+found>0 report "search did not visit any nodes" severity failure;
        get(10,completed_depth);get(11,search_flags);get(12,hi);get(13,lo);get(14,n);get(15,found);
        cache_hits:=hi*16777216+lo*65536+n*256+found;
        get(64,pv_length); assert pv_length>0 and pv_length<=SEARCH_LEVELS report "Missing completed PV prefix" severity failure;
        get(25,n);assert n>=EXPECT_MIN_PLY report "Search did not exercise required stack depth" severity failure;
        get(65,hi);get(66,lo);assert hi*256+lo=best report "Published PV does not start with selected move" severity failure;
        if DETERMINISTIC then
          pv_text:=new string'("PV position="&integer'image(test_count)&" moves=");
          for j in 0 to pv_length-1 loop
            get(65+j*2,hi);get(66+j*2,lo);write(pv_text,integer'image(hi*256+lo)&" ");
          end loop;
          report pv_text.all; deallocate(pv_text);
        end if;
        profile_sum:=0;
        for g in 0 to 6 loop
          get(36+g*4,hi);get(37+g*4,lo);get(38+g*4,n);get(39+g*4,found);
          profile_sum:=profile_sum+hi*16777216+lo*65536+n*256+found;
          if DETERMINISTIC then report "PHASE position="&integer'image(test_count)&" group="&integer'image(g)&" cycles="&integer'image(hi*16777216+lo*65536+n*256+found); end if;
        end loop;
        get(98,hi);get(99,lo);get(100,n);get(101,found);snapshot_cycles:=hi*16777216+lo*65536+n*256+found;
        assert profile_sum=snapshot_cycles report "Phase cycle counters do not reconcile" severity failure;
        packet(0):=x"00";send(1);get(16,hi);get(17,lo);get(18,n);get(19,found);
        decision_cycles:=hi*16777216+lo*65536+n*256+found;
        report "BENCH position="&integer'image(test_count)&" best="&integer'image(best)&
          " completed="&integer'image(completed_depth)&" nodes="&integer'image(nodes)&
          " cache_hits="&integer'image(cache_hits)&" cycles="&integer'image(decision_cycles)&
          " score="&integer'image(activation);
        if CACHE_ENABLE=0 then assert cache_hits=0 report "Disabled cache was used" severity failure; end if;
        if EXPECT_TIMEOUT then
          assert search_flags mod 2=1 and completed_depth>=2 and completed_depth<SEARCH_DEPTH
            report "Budget did not publish an earlier completed iteration" severity failure;
        end if;
        if BUDGET_SECONDS=0 and completed_depth/=0 then
          assert completed_depth=SEARCH_DEPTH report "Search did not finish the requested depth" severity failure;
        end if;
      end if;
      for page in 0 to 15 loop
        if page*16<count then
          packet(0):=x"13";packet(1):=oct(page);send(2);
          for i in 0 to 15 loop
            if page*16+i<count then get(i,n);page_metadata(i):=oct(n);else page_metadata(i):=x"00";end if;
          end loop;
          packet(0):=x"07"; packet(1):=oct(page); send(2);
          for i in 0 to 15 loop
            if page*16+i<count then
              get(i*4,hi); get(i*4+1,lo); move:=hi*256+lo;
              assert seen(move) report "unexpected or duplicated move "&integer'image(move)&
                " at position "&integer'image(test_count) severity failure;
              seen(move):=false;
              get(i*4+2,hi); get(i*4+3,lo); activation:=hi*256+lo;
              if activation>=32768 then activation:=activation-65536; end if;
              expected_scores(move):=activation;
              expected_kinds(move):=to_integer(unsigned(page_metadata(i)))/64;
              if DETERMINISTIC or REPORT_SCORES then
                report "CACHE_SCORE position="&integer'image(test_count)&" move="&integer'image(move)&
                  " value="&integer'image(activation)&" bound="&integer'image(to_integer(unsigned(page_metadata(i)))/64);
              end if;
            end if;
          end loop;
        end if;
      end loop;
      if count>0 then
        selected_kind:=3;
        for page in 0 to 15 loop
          if page*16<count then
            packet(0):=x"07";packet(1):=oct(page);send(2);
            for i in 0 to 15 loop
              if page*16+i<count then
                get(i*4,hi);get(i*4+1,lo);
                if hi*256+lo=best then
                  packet(0):=x"13";packet(1):=oct(page);send(2);get(i,meta);
                  selected_kind:=meta/64;
                  assert meta mod 16=completed_depth or SEARCH_DEPTH=0 report "Candidate depth does not match published iteration" severity failure;
                  packet(0):=x"07";packet(1):=oct(page);send(2);
                end if;
              end if;
            end loop;
          end if;
        end loop;
        assert selected_kind=0 report "Selected move has an inexact bound" severity failure;
      end if;
      for detail_page in 0 to 63 loop
        if detail_page*4<count then
          packet(0):=x"0E"; packet(1):=oct(detail_page); send(2);
          for i in 0 to 3 loop
            if detail_page*4+i<count then
              get(i*18,hi); get(i*18+1,lo); move:=hi*256+lo;
              get(i*18+2,hi); get(i*18+3,lo); activation:=hi*256+lo;
              if activation>=32768 then activation:=activation-65536; end if;
              assert activation=expected_scores(move) report "candidate explanation header mismatch" severity failure;
              parts:=0;
              for j in 0 to 6 loop
                get(i*18+4+j*2,hi); get(i*18+5+j*2,lo); part:=hi*256+lo;
                if part>=32768 then part:=part-65536; end if;
                parts:=parts+part;
              end loop;
              assert clip16(parts)=activation report "candidate components do not sum to activation" severity failure;
            end if;
          end loop;
        end if;
      end loop;
      if CHECK_TACTICS and focus_move>=0 then
        report "behavior activation: focus "&integer'image(expected_scores(focus_move))&" versus alternative "&integer'image(expected_scores(other_move));
        if expected_kinds(focus_move)=0 and expected_kinds(other_move)=0 then
          assert expected_scores(focus_move)>expected_scores(other_move)+score_gap report "tactical move was not rewarded" severity failure;
        elsif score_gap>0 then
          -- A loose upper bound is not an exact runner-up evaluation.
          assert best/=other_move report "Selected the independently identified inferior tactical move" severity failure;
        end if;
      end if;
      packet(0):=x"04"; send(1);
      for i in 0 to 15 loop
        get(i,n); assert oct(n)=expected_maps(i) report "attack map mismatch" severity failure;
      end loop;
      if CHECK_TACTICS and commit_expected then
        packet(0):=x"00"; send(1);
        packet(0):=x"0B";
        for i in 0 to 3 loop get(20+i,n); packet(1+i):=oct(n); end loop;
        packet(5):=oct(best/256); packet(6):=oct(best); send(7);
        wait for 2 us*CLOCK_DIVIDE;
        packet(0):=x"05"; send(1);
        for i in 0 to 66 loop
          get(i,n); assert oct(n)=committed_position(i) report "searched move committed with incorrect board/rights/EP/turn" severity failure;
        end loop;
        packet(0):=x"0B"; send(7,3);
      end if;
      test_count:=test_count+1;
      report "position "&integer'image(test_count)&" passed ("&integer'image(count)&" legal moves)";
    end loop;
    report "PASS: independent python-chess legal sets and attack maps: "&integer'image(test_count-FIRST_POSITION);
    -- Routing moved from flip-flops to M4K. Verify the entire native-clock
    -- response path, including the register/RAM boundary at byte 16.
    packet(0):=x"08";
    for i in 1 to 80 loop packet(i):=oct(i*37+11); end loop;
    send(81); packet(0):=x"06"; send(1);
    for i in 0 to 79 loop
      get(i,n); assert oct(n)=packet(i+1) report "configuration/routing RAM readback mismatch" severity failure;
    end loop;
    -- Exercise writable RAM tables and cold-start validity, not just defaults.
    packet:=(others=>x"00"); packet(0):=x"08"; packet(5):=x"01";
    for i in 17 to 80 loop packet(i):=x"FF"; end loop;
    send(81);
    runtime_policy(10):=x"00";
    runtime_policy(11):=x"01";
    for i in 24 to 39 loop runtime_policy(i):=x"20"; end loop;
    for model_page in 0 to 1 loop
      packet(0):=x"0D"; packet(1):=oct(model_page);
      for i in 0 to 63 loop packet(i+2):=runtime_policy(model_page*64+i); end loop;
      send(66);
      packet(0):=x"0C"; packet(1):=oct(model_page); send(2);
      for i in 0 to 63 loop get(i,n); assert oct(n)=runtime_policy(model_page*64+i) report "policy RAM readback mismatch" severity failure; end loop;
    end loop;
    packet(0):=x"0A"; send(1); packet(0):=x"02"; send(1);
    for poll in 0 to 999 loop
      wait for 100 us*CLOCK_DIVIDE; packet(0):=x"00"; send(1); get(5,n); exit when n=1;
    end loop;
    assert n=1 report "response-table evaluation timed out" severity failure;
    packet(0):=x"04"; send(1);
    for i in 16 to 79 loop get(i,n); assert n=32 report "programmable response did not reach every cell" severity failure; end loop;
    runtime_policy(11):=x"00";
    for i in 16 to 23 loop runtime_policy(i):=x"00"; end loop;
    runtime_policy(64+27):=x"50";
    for model_page in 0 to 1 loop
      packet(0):=x"0D"; packet(1):=oct(model_page);
      for i in 0 to 63 loop packet(i+2):=runtime_policy(model_page*64+i); end loop;
      send(66);
    end loop;
    packet(0):=x"0A"; send(1); packet(0):=x"02"; send(1);
    for poll in 0 to 999 loop
      wait for 100 us*CLOCK_DIVIDE; packet(0):=x"00"; send(1); get(5,n); exit when n=1;
    end loop;
    packet(0):=x"04"; send(1);
    for i in 0 to 63 loop
      get(i+16,n);
      if i=27 then assert n=80 report "local bias missing" severity failure;
      else assert n=0 report "old RAM activity leaked through position reset" severity failure; end if;
    end loop;
    report "PASS: runtime response LUT, both policy RAM pages, local bias and cold-start state";
    running<=false; wait;
  end process;
end;
