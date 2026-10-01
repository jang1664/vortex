class VX_randomizer;
  rand int b;
  local static VX_randomizer singleton;
  local function new;
  endfunction
  static function VX_randomizer get;
    if(singleton==null)
      singleton = new();
    return singleton;
  endfunction
  function int local_urandom;
    assert( randomize() with {b inside {[10:100]};} );
    return b;
  endfunction
endclass : VX_randomizer

// module leaf_mdl();
//     randomizer a;
//     int b;
//     logic c;
//     always @(posedge c) begin
//         b =a.local_urandom();
//         $display("In local_urandom %0t %m - %0d", $time, b);
//     end
 
//     initial begin
//       a = randomizer::get();
//       c = 0;
//     end
// endmodule
 
// module main_mdl();
//     leaf_mdl#() leaf_mdl_inst0 ();
//     leaf_mdl#() leaf_mdl_inst1 ();
 
//     initial begin
//         #2;
//         leaf_mdl_inst0.c = 1;
//         #1000;
//         leaf_mdl_inst1.c = 1;
//         #2;
//         $display ("module A value -  %0d, module B value %0d\n", leaf_mdl_inst0.b, leaf_mdl_inst1.b);
 
//         $finish;
//     end
// endmodule