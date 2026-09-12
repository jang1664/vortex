source agent-tasks/naive-psum-read-priority/baseline-naive.sh
CONFIGS+=" -DGEMM_NAIVE_PSUM_READ_PRIORITY -DGEMM_NAIVE_PSUM_READ_QUOTA=4"
export CONFIGS
