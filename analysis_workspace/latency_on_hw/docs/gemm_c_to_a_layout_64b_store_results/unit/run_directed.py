import datetime,importlib.util,json,pathlib,shutil,subprocess,sys
repo=pathlib.Path('/home/jaeyongjang/project.local/vortex_fpint-feat-gemv')
build=repo/'build_gemm_c_to_a_unit'
root=repo/'analysis_workspace/latency_on_hw/docs/gemm_c_to_a_layout_64b_store_results'
spec=importlib.util.spec_from_file_location('verify_rtl',repo/'tools/verify_rtl.py')
v=importlib.util.module_from_spec(spec);spec.loader.exec_module(v)
reports=[]
for m,k,n,repeat in [(1,16,16,1),(1,16,48,1),(3,16,48,1),(1,16,144,1),(132,16,144,1),(1,16,32,2)]:
    name=f'm{m}_k{k}_n{n}_r{repeat}'
    d=root/'directed'/name;d.mkdir(parents=True,exist_ok=False)
    args=f'-m {m} -k {k} -n {n} -q 32 -t 0 -d 0 -r {repeat} --tagged'
    command='source ../configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4.sh\nexport CC=/usr/bin/gcc CXX=/usr/bin/g++\ntimeout -k 10 300 bash ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw --args "'+args+'" --perf 3'
    (d/'command.txt').write_text('cwd='+str(build)+'\n'+command+'\n')
    (d/'start.txt').write_text(datetime.datetime.now().isoformat()+'\n')
    print('START '+name,flush=True)
    with (d/'run.log').open('w') as log:
        rc=subprocess.run(['bash','-c',command],cwd=build,stdout=log,stderr=subprocess.STDOUT).returncode
    (d/'exit_code.txt').write_text(str(rc)+'\n')
    (d/'end.txt').write_text(datetime.datetime.now().isoformat()+'\n')
    for file in ['simv.log','compile.log']:
        src=build/'sim/xrtsim_vcs'/file
        if src.exists():shutil.copy2(src,d/file)
    log=(d/'run.log').read_text(errors='replace')
    ok=rc==0 and v.check_pass(log)
    report=dict(status='pass' if ok else 'sim_fail',test_name=name,exit_code=rc,error_log='' if ok else v.extract_errors(log),log_file=str(d/'run.log'))
    (d/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    reports.append(report)
    (root/'unit/directed_verify_rtl_reports.json').write_text(json.dumps(reports,indent=2)+'\n')
    print(json.dumps(report),flush=True)
    if not ok:sys.exit(1)
