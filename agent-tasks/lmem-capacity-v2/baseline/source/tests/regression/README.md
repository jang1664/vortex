# bench setup
- build third party
  - git submodule init; git submodule update
  - ```make -C ../third_party```
- build kernel
  - ```make -C kernel```
- fetch nesscary files
  - git restore --source origin/fpint_improve -- tests/common
  - git restore --source origin/fpint_improve -- tests/regression
  - git restore --source origin/fpint_improve -- ci

# llama2 ops
- eldiv
- eladd
- softmax
- elreduce
- silu
- rmsnorm
- elsub
- elscalar
- sgemm_tcu
- elmul
- rope
- dropout
- elunary