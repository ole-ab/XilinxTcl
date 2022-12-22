######################################################################
# Automatically inserts ILA instances
# 1) Script looks for nets marked with MARK_DEBUG attribute. 
# 2) In case such net is present it checks value of xlnx_ila_name
# attribute of found net.
# 3) If this attribute is not null string, script creattes ILA with 
# this name given by xlnx_ila_name and connects given net to the created ILA.
# 4) Then scripts looks for net with <xlnx_ila_name>_clk attribute and connects
# this net to clock port of created ILA.
# 5) In case of several ILA are created scripts connects trigger ports
# of ILA in circle-like fashion.

# Illustration of scheme implemented by script.
# "->" - trigger ports
# |ILA| - Xilinx ILA IP core
#           Scheme
#
# |ILA| -> |ILA| -> |ILA|
#   ^                 |
#   |                 v
# |ILA| <- |ILA| <- |ILA|

# SystemVerilog example. This code is verified in Vivado 2021.1.
# Signal to debug must be marked the way showed below.
# (* mark_debug = "true" *) (* dont_touch = "true" *) (* xlnx_ila_name = "u_my_ila_0" *) logic comb_rstn;
# (* mark_debug = "true" *) (* dont_touch = "true" *) (* xlnx_ila_name = "u_my_ila_1" *) logic rst_hil_cpu_n;
# Clocks for ILAs must be marked the way showed below.
# (* dont_touch = "true" *) (* u_my_ila_0_clk *) (* u_my_ila_1_clk *)logic my_clk;
    
    ##################################################################
    # sequence through debug nets and organize them by their target ila in the
    # ila2buslist_table array. Also create max and min array for bus indices

    puts "<><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>"
    puts "<><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>"
    puts "<><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>"
    puts "Insertion of ila started"

    set dbg_nets [get_nets -hierarchical -filter {MARK_DEBUG}]
    if {[llength $dbg_nets] == 0} {
        puts "No nets to debug"
        return
    }
    puts "Nets to debug are below:"
    puts $dbg_nets


    puts "Clock in project are below:"
    puts [get_clocks]
   

    foreach dbg_net $dbg_nets {
        # bus_name is root name of a bus, bus_index is the bit in the bus
        set bus_name [regsub {\[[[:digit:]]+\]$} $dbg_net {}]
        set bus_index [regsub {^.*\[([[:digit:]]+)\]$} $dbg_net {\1}]
        if {[string is integer -strict $bus_index]} {
            if {![info exists max($bus_name)]} {
                set max($bus_name) $bus_index
                set min($bus_name) $bus_index
            } elseif {$bus_index > $max($bus_name)} {
                set max($bus_name) $bus_index
            } elseif {$bus_index < $min($bus_name)} {
                set min($bus_name) $bus_index
            }
        } else {
            set max($bus_name) -1
        }

       if {![info exists bus2ila_table($bus_name)]} {
            if {[llength $dbg_net] > 0} {
                if {[llength [get_property xlnx_ila_name $dbg_net]] == 0} {
                    puts "Net $dbg_net has not got respective ILA marked by xlnx_ila_name attribute in RTL code.    \
                         It will not be added to ILA probe list by this script"
                } else {
                    # bus2ila_table shows correspondance between certain bus and ILA.
                    set bus2ila_table($bus_name) [get_property xlnx_ila_name $dbg_net]
                    if {![info exists ila2buslist_table($bus2ila_table($bus_name))]} {
                        # found a new clock
                        puts "ILA with name $bus2ila_table($bus_name) will be created"
                        # bus2ila_table shows correspondance between certain ILA and bus.
                        set ila2buslist_table($bus2ila_table($bus_name)) [list $bus_name]
                    } else {
                        puts "Net with name $bus_name added to ILA $bus2ila_table($bus_name)"
                        lappend ila2buslist_table($bus2ila_table($bus_name)) $bus_name
                    }
                }
            }
        }
    }
    puts "Following ILAs will be created:"
    puts [array names ila2buslist_table]
    puts "Following nets will be probed:"
    foreach i [array names ila2buslist_table] {puts $ila2buslist_table($i)}
    
    foreach ila_name [array names ila2buslist_table] {
        set ila_inst $ila_name
        puts "ILA $ila_name will be created with instance name $ila_inst"
        # Find dedicated clock for our ILA
        set clk_net [get_nets -hierarchical -filter "${ila_name}_CLK == 1"]

        if {$clk_net == ""} {
            error "Couldn't find clock for $ila_inst. Mark clock with XLNX_ILA_CLK = your_ila_CLK attribute"
            return
        } else {
            puts "ILA with name $ila_inst will have dedicated clock $clk_net"
        }
        
        puts "Creating ILA $ila_inst"
        ##################################################################
        # create ILA and connect its clock
        create_debug_core  $ila_inst        ila
        set_property       C_DATA_DEPTH             1024    [get_debug_cores $ila_inst]
        set_property       C_TRIGOUT_EN             true    [get_debug_cores $ila_inst]
        set_property       C_TRIGIN_EN              true    [get_debug_cores $ila_inst]
        set_property       C_EN_STRG_QUAL           1       [get_debug_cores $ila_inst]
        set_property       C_INPUT_PIPE_STAGES      2       [get_debug_cores $ila_inst]
        set_property       C_ADV_TRIGGER            true    [get_debug_cores $ila_inst]
        set_property       ALL_PROBE_SAME_MU        true    [get_debug_cores $ila_inst]
        set_property       ALL_PROBE_SAME_MU_CNT    4       [get_debug_cores $ila_inst]
        set_property       port_width               1       [get_debug_ports $ila_inst/clk]
    
        connect_debug_port $ila_inst/clk    $clk_net
        ##################################################################
        # add probes
        set probes_qty 0
        foreach net [lsort $ila2buslist_table($ila_name)] {
            puts "Preparing bus $net for ILA $ila_name)"
            set nets {}
            if {$max($net) < 0} {
                puts "Net $net is not a bus, but single net"
                lappend nets [get_nets $net]
            } else {
                puts "Net $net is a bus with maximum bit  index $max($net)"
                # net is a bus bus_name
                for {set i $min($net)} {$i <= $max($net)} {incr i} {
                    lappend nets [get_nets $net[$i]]
                }
            }
            set prb probe$probes_qty
            if {$probes_qty > 0} {
                puts "create_debug_port $ila_inst probe"
                create_debug_port $ila_inst probe
            }
            puts "set_property port_width [llength $nets] [get_debug_ports $ila_inst/$prb]"
            set_property port_width [llength $nets] [get_debug_ports $ila_inst/$prb]
            puts "connect_debug_port $ila_inst/$prb $nets"
            connect_debug_port $ila_inst/$prb $nets
            incr probes_qty
        }
    }
    
    ##################################################################
    # Create trigger ports
    # Connect all ILAs in circle so each one can trigger each one.
    puts "Connecting trigger ports of ILAs"
    if {[info exists i]} {unset i}
    set i 0
    if {[info exists ila_names_array]} {unset ila_names_array}
    array set ila_names_array {}
    foreach ila_name [array names ila2buslist_table] {
        append ila_names_array($i) $ila_name
        puts "$i) ILA $ila_names_array($i) is found. Total number of found ILAs is [array size ila_names_array]"
        set i [expr ($i + 1)]   
    }

    set ila_qty [array size ila_names_array]
    puts "$ila_qty ILAs will be connected to each other"

    for {set i 0} {$i < $ila_qty} {incr i} {
        create_debug_port $ila_names_array($i) trig_in
        create_debug_port $ila_names_array($i) trig_in_ack
        create_debug_port $ila_names_array($i) trig_out
        create_debug_port $ila_names_array($i) trig_out_ack
        puts "$i)Trigger ports created for $ila_names_array($i)"
    }

    for {set i 0} {$i < [expr $ila_qty-1]} {incr i} {
        # If only 1 ILA is present it has nothing to be connected to.
        # if {$i > 0 && $i < [expr $ila_qty-1]} {
            puts "<><>0"
            # connect_debug_port $ila_names_array([expr $i-1])/trig_out       $ila_names_array($i)/trig_in
            puts "<><>1"
            # onnect_debug_port $ila_names_array([expr $i-1])/trig_in_ack    $ila_names_array($i)/trig_out_ack
            puts "<><>2"
            connect_debug_port $ila_names_array($i)/trig_out                $ila_names_array([expr $i+1])/trig_in        
            puts "<><>3"
            connect_debug_port $ila_names_array($i)/trig_in_ack             $ila_names_array([expr $i+1])/trig_out_ack   
            puts "<><>4"
        # }
    }

    # Connect last and first ila in circle
    puts "Lock the circle connecting last and first ILA"

    connect_debug_port $ila_names_array([expr $ila_qty-1])/trig_out         $ila_names_array(0)/trig_in
    connect_debug_port $ila_names_array([expr $ila_qty-1])/trig_in_ack      $ila_names_array(0)/trig_out_ack


    puts "Insertion of ila finished"
    puts "<><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>"
    puts "<><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>"
    puts "<><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>"
    
    ##################################################################
    # write out probe info file
#    write_debug_probes my_insert_ila.ltx
