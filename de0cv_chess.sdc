create_clock -name board_clock -period 20.000 [get_ports CLOCK_50]
derive_clock_uncertainty
set_false_path -from [get_ports {RESET_N KEY[0]}]
set_false_path -from [get_ports {KEY[1]}] -to [get_registers {key_meta}]
set spi_first_stages [get_registers {*|sclk_meta *|cs_meta *|mosi_meta}]
if {[get_collection_size $spi_first_stages] != 3} {error "SPI input synchronizers were not found"}
set_false_path -from [get_ports {SPI_SCLK SPI_CS_N SPI_MOSI}] -to $spi_first_stages
# SPI outputs are asynchronous to the board clock; the target oversamples mode-0 SPI.
set_false_path -to [get_ports {SPI_MISO IRQ_N LEDR[*] HEX0[*] HEX1[*] HEX2[*] HEX3[*] HEX4[*] HEX5[*]}]
# Engine advances only on its common four-cycle enable. RAM ports and host registers remain single-cycle.
set chess_ce_registers [get_registers {*|chess_engine:engine|state* *|chess_engine:engine|base* *|chess_engine:engine|b* *|chess_engine:engine|src* *|chess_engine:engine|dst* *|chess_engine:engine|promotion* *|chess_engine:engine|wk* *|chess_engine:engine|bk* *|chess_engine:engine|trial_king* *|chess_engine:engine|moving* *|chess_engine:engine|captured* *|chess_engine:engine|en_passant* *|chess_engine:engine|castling* *|chess_engine:engine|promoting* *|chess_engine:engine|in_check* *|chess_engine:engine|done* *|chess_engine:engine|legal_count* *|chess_engine:engine|best_move* *|chess_engine:engine|best_score* *|chess_engine:engine|white_map* *|chess_engine:engine|black_map* *|chess_engine:engine|field* *|chess_engine:engine|node_* *|chess_engine:engine|cursor_* *|chess_engine:engine|search_sp* *|chess_engine:engine|search_index* *|chess_engine:engine|search_active* *|chess_engine:engine|search_returning* *|chess_engine:engine|search_root_move* *|chess_engine:engine|search_parts* *|chess_engine:engine|search_nodes* *|chess_engine:engine|search_cutoffs* *|chess_engine:engine|search_result* *|chess_engine:engine|search_sum_* *|chess_engine:engine|search_delta_score* *|chess_engine:engine|trial_static* *|chess_engine:engine|packet_rx* *|chess_engine:engine|packet_length* *|chess_engine:engine|packet_token* *|chess_engine:engine|command_pending* *|chess_engine:engine|cfg* *|chess_engine:engine|route_index* *|chess_engine:engine|turn* *|chess_engine:engine|rights* *|chess_engine:engine|ep* *|chess_engine:engine|neuron_index* *|chess_engine:engine|neuron_direction* *|chess_engine:engine|neuron_result* *|chess_engine:engine|neuron_old* *|chess_engine:engine|neuron_bias* *|chess_engine:engine|neighbor_accum* *|chess_engine:engine|policy* *|chess_engine:engine|history* *|chess_engine:engine|nonpawn_count* *|chess_engine:engine|audit_* *|chess_engine:engine|load_* *|chess_engine:engine|relax_left* *|chess_engine:engine|relax_timer* *|chess_engine:engine|old_keys* *|chess_engine:engine|last_token* *|chess_engine:engine|have_token* *|chess_engine:engine|cached_status* *|chess_engine:engine|score_* *|chess_engine:engine|candidate_write_* *|chess_engine:engine|response_kind* *|chess_engine:engine|response_status_i* *|chess_engine:engine|response_length* *|chess_engine:engine|page* *|chess_engine:engine|elapsed* *|chess_engine:engine|generation*}]
set expanded_ce_registers [get_registers {*|chess_engine:engine|eval_* *|chess_engine:engine|completed_* *|chess_engine:engine|candidate_bank* *|chess_engine:engine|published_bank* *|chess_engine:engine|search_building* *|chess_engine:engine|search_iteration* *|chess_engine:engine|search_completed* *|chess_engine:engine|search_timed_out* *|chess_engine:engine|search_has_completed* *|chess_engine:engine|search_running* *|chess_engine:engine|search_limit* *|chess_engine:engine|search_epoch* *|chess_engine:engine|search_cache_* *|chess_engine:engine|search_hash_acc* *|chess_engine:engine|search_scan* *|chess_engine:engine|search_pick_* *|chess_engine:engine|search_clear_index* *|chess_engine:engine|queue_write_* *|chess_engine:engine|cache_write_* *|chess_engine:engine|history_write_*}]
set chess_ce_registers [add_to_collection $chess_ce_registers $expanded_ce_registers]
set advanced_ce_registers [get_registers {*|chess_engine:engine|root_* *|chess_engine:engine|phase_counters* *|chess_engine:engine|max_tactical_depth* *|chess_engine:engine|chosen_static_* *|chess_engine:engine|stats_snapshot* *|chess_engine:engine|iteration_pv* *|chess_engine:engine|pv_write_data* *|chess_engine:engine|pv_write_address* *|chess_engine:engine|see_move* *|chess_engine:engine|see_ep* *|chess_engine:engine|see_promotion* *|chess_engine:engine|see_calls* *|chess_engine:engine|see_cycles*}]
set chess_ce_registers [add_to_collection $chess_ce_registers $advanced_ce_registers]
set chess_ce_registers [add_to_collection $chess_ce_registers [get_registers {*|chess_engine:engine|stack_group_*}]]
set chess_ce_registers [add_to_collection $chess_ce_registers [get_registers {*|chess_engine:engine|status_cycles*}]]
set request_ce_registers [get_registers {*|chess_engine:engine|response_request* *|chess_engine:engine|candidate_request* *|chess_engine:engine|queue_request* *|chess_engine:engine|cache_request* *|chess_engine:engine|history_request* *|chess_engine:engine|pv_request* *|chess_engine:engine|see_request*}]
set chess_ce_registers [add_to_collection $chess_ce_registers $request_ce_registers]
# Cyclone V packs main-controller arithmetic registers into DSP input/output
# banks and names the timing nodes Mult<N>~<N>. Every variable multiplier in
# chess_engine is inside the phase=0 controller branch. Include only those
# direct DSP data nodes; native ENA_DFF helpers and the separate SEE instance
# deliberately retain single-cycle timing checks.
set engine_dsp_registers [get_registers -nowarn {*|chess_engine:engine|Mult*}]
set dsp_native_helpers [get_registers -nowarn {*|chess_engine:engine|Mult*|*}]
set packed_dsp_ce_registers [remove_from_collection $engine_dsp_registers $dsp_native_helpers]
# Before packing these aliases can be absent; the original RTL names above
# cover that netlist. Post-fit timing sees the generated DSP data aliases.
puts "Enabled DSP data registers: [get_collection_size $packed_dsp_ce_registers] (native DSP enable helpers excluded)"
set chess_ce_registers [add_to_collection $chess_ce_registers $packed_dsp_ce_registers]
# SEE and RAM outputs advance on native clocks. Request registers advance on
# the common enable; their native strobes are short phase decodes.
# No multicycle exception applies within the exchange analyzer or SPI endpoint.
if {[get_collection_size $chess_ce_registers] == 0} {error "Chess enable register bank was not found"}
set_multicycle_path -setup 4 -from $chess_ce_registers -to $chess_ce_registers
set_multicycle_path -hold 3 -from $chess_ce_registers -to $chess_ce_registers
