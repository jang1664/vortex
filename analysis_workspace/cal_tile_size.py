import numpy as np
import itertools

if __name__ == "__main__":
  MT=[128, 256, 512, 1024]
  KT=[128, 256, 512, 1024]
  NT=[128, 256, 512, 1024]
  QB=[32, 64, 128]

  succeed = []
  for mt, kt, nt, qb in itertools.product(MT, KT, NT, QB):
    input_size = mt * kt * 2 * 2
    output_size = mt * nt * 2 * 2
    weight_size = kt * nt * 0.5 * 2
    scale_zp_size = (kt * nt) / qb * 2 * 2 * 2
    total_size = (input_size + output_size + weight_size + scale_zp_size)/1024

    if KT >= QB:
      print(f"MT={mt}, KT={kt}, NT={nt}, QB={qb} -> {total_size} / {512} : {total_size <= 512}")
      if total_size <= 512:
        succeed.append((mt, kt, nt, qb))

  print("Succeeding combinations:")
  for mt, kt, nt, qb in succeed:
    print(f"MT={mt}, KT={kt}, NT={nt}, QB={qb}")