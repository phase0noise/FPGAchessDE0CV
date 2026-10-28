package require ::quartus::project
package require ::quartus::sta
project_open de0cv_chess
create_timing_netlist
read_sdc
update_timing_netlist
set failed 0
foreach_in_collection oc [get_available_operating_conditions] {
    set_operating_conditions $oc
    update_timing_netlist
    foreach check {setup hold recovery removal} {
        set paths [get_timing_paths -$check -npaths 1]
        foreach_in_collection path $paths {
            set slack [get_path_info -slack $path]
            puts "[get_operating_conditions_info -display_name $oc] $check slack: $slack ns"
            if {$slack < 0} { set failed 1 }
        }
    }
    set corner [string map {" " _ "/" _} [get_operating_conditions_info -display_name $oc]]
    report_timing -setup -npaths 20 -nworst 1 -detail full_path -file ".cache/critical-$corner.rpt"
    # Keep native sources and endpoints visible even when many slow controller
    # paths would otherwise fill the report with one arithmetic family.
    set native_registers [remove_from_collection [get_registers {*}] $chess_ce_registers]
    report_timing -setup -npaths 10 -nworst 1 -from $native_registers -detail full_path -file ".cache/critical-native-from-$corner.rpt"
    report_timing -setup -npaths 10 -nworst 1 -to $native_registers -detail full_path -file ".cache/critical-native-to-$corner.rpt"
}
if {[get_collection_size [get_clocks board_clock]] != 1} { set failed 1 }
delete_timing_netlist
project_close -dont_export_assignments
if {$failed} { error "Timing requirements were not met" }
