#!/usr/bin/env python3
"""Positive and adversarial fixtures for the decoder trace acceptance path."""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
FLASH = HERE.parent / "flash_attn"
sys.path.insert(0, str(FLASH))
from decoder_traffic_manifest import DecoderTrafficManifest
from decoder_runtime import contract, write_region
from check_attention_traffic import verify_completion, verify_inputs, verify_ledger


def physical(address):
    block, byte = divmod(address, 64)
    channel_block, port = divmod(block, 4)
    row, bank = divmod(channel_block, 8)
    return (port*8+bank)*(1<<29)+row*64+byte


def fixture():
    d = dict(schema="c4_decoder_attention_traffic_v1", backend="resident",
      model=dict(name="llama3-8b",batch=1,seq=1,stage="decode",past_kv=16,capacity=32,
                 q_heads=32,kv_heads=8,head_dim=128),
      geometry=dict(banks=32,ports=4,beat_bytes=64,address_bits=34,cores=1,warps=4,threads=16),
      snapshot=dict(path="unused-fixture"),buffers=[],records=[],
      arguments=dict(base=0x900000,bytes=4096,record_bytes=512),
      dispatch=dict(base=0x910000,bytes=16,operation=10,args_base=0x900000,count=8))
    buffers = {}
    def add(name,role,size):
        base = 0x10000*(len(buffers)+1)
        b=dict(name=name,role=role,base=hex(base),bytes=size,layout="fixture",matrices=1,rows=1,cols=1)
        d["buffers"].append(b);buffers[name]=base
    add("q_hadamard","q",16384);add("context","context",16384)
    for h in range(8):
        for kind,short in (("key","k"),("value","v")):
            for part,size in (("weight",2048),("scale",512),("zero",512)):
                add(f"{kind}.0.{h}.{part}",f"{short}_{part}",size)
        for kind,role,size in (("key_pad","pad_k_weight",8192),("value_pad","pad_v_weight",8192),
                               ("value_scale_pad","pad_v_scale",2048),("value_zero_pad","pad_v_zero",2048)):
            add(f"attention.{kind}.0.{h}",role,size)
        a=dict(query_rows=4,query_rows_pad=8,kv_length=17,kv_tile=128,head_dim=128,qk_qblk=128,
               qk_wtrans=1,qk_qdir=0,pv_qblk=128,pv_wtrans=0,pv_qdir=1,causal=0,pv_only=0,
               resident=1,debug_export=0,debug_stage=0,output_tiled=1,query_position_base=0,output_fp32=0)
        for key,name,off in (("q","q_hadamard",h*2048),("output","context",h*2048),
          ("k_weight",f"attention.key_pad.0.{h}",0),("k_scale",f"key.0.{h}.scale",0),
          ("k_zero",f"key.0.{h}.zero",0),("v_weight",f"attention.value_pad.0.{h}",0),
          ("v_scale",f"attention.value_scale_pad.0.{h}",0),("v_zero",f"attention.value_zero_pad.0.{h}",0)):
            a[key+"_base"]=buffers[name]+off
        for key,size in (("k_weight",8192),("k_scale",512),("k_zero",512),("v_weight",8192),("v_scale",2048),("v_zero",2048)):
            a[key+"_tile_bytes"]=size
        for i,key in enumerate(("score","probability","partial","accumulator","row_max","row_sum","row_alpha")):
            a[key+"_base"]=0x1ffc00000+i*4096
        d["records"].append(dict(index=h,batch=0,query_head_start=h*4,kv_head=h,row_start=0,attention=a,
          key_source=buffers[f"key.0.{h}.weight"],key_source_bytes=2048,key_padded_bytes=8192,
          value_source=buffers[f"value.0.{h}.weight"],value_scale_source=buffers[f"value.0.{h}.scale"],
          value_zero_source=buffers[f"value.0.{h}.zero"],value_source_rows=32))
    return d


def fixture_c256():
    d = fixture()
    d["model"].update(past_kv=128, capacity=256)
    d["buffers"] = [b for b in d["buffers"] if not b["role"].startswith("pad_")]
    for b in d["buffers"]:
        if b["role"] in {"k_weight", "v_weight"}: b["bytes"] = 16384
        elif b["role"] in {"k_scale", "k_zero"}: b["bytes"] = 1024
        elif b["role"] in {"v_scale", "v_zero"}: b["bytes"] = 4096
    buffers = {b["name"]: int(b["base"], 16) for b in d["buffers"]}
    for i, record in enumerate(d["records"]):
        record["attention"]["kv_length"] = 129
        for short, kind in (("k", "key"), ("v", "value")):
            for field in ("weight", "scale", "zero"):
                record["attention"][f"{short}_{field}_base"] = buffers[f"{kind}.0.{i}.{field}"]
        for field in ("key_source", "key_source_bytes", "key_padded_bytes", "value_source",
                      "value_scale_source", "value_zero_source", "value_source_rows"):
            record[field] = 0
    return d


def fixture_c160():
    d=fixture_c256();d["model"]["capacity"]=160
    for b in d["buffers"]:
        if b["role"]=="k_weight":b["bytes"]=10240
    for h,record in enumerate(d["records"]):
        original=record["attention"]["k_weight_base"];padded=0x700000+h*0x10000
        d["buffers"].append(dict(name=f"attention.key_pad.0.{h}",role="pad_k_weight",
            base=hex(padded),bytes=16384,layout="packed_attention_input",matrices=1,rows=1,cols=1))
        record["attention"]["k_weight_base"]=padded
        record.update(key_source=original,key_source_bytes=10240,key_padded_bytes=16384)
    return d


def trace_for(d):
    lines=[]
    # Expected transfers are specified independently of the manifest adapter.
    for record in d["records"]:
        for name,size,stride in (("q",2048,0),("k_weight",8192,8192),("k_scale",256,512),
                                ("k_zero",256,512),("v_weight",8192,8192),
                                ("v_scale",2048,2048),("v_zero",2048,2048)):
            count = 2 if d["model"]["past_kv"] == 128 and name != "q" else 1
            for tile in range(count):
                for off in range(0,size,64):
                    address=physical(record["attention"][name+"_base"]+tile*stride+off)
                    lines += [f"gemm:tmem:dma ch=0 AR_FIRE addr={address:#x} len=0",
                              f"1: AXI Rd Req [0]: addr={address:#x}", "AXI Rd Rsp"]
    pointer=d["dispatch"]["base"]
    for register,value in ((3,pointer&0xffffffff),(4,pointer>>32)):
        lines += [f"[TB] REG_WRITE: offset=0x20 value={register:#x}",f"[TB] REG_WRITE: offset=0x24 value={value:#x}"]
    for b in d["buffers"]:
        if b["role"]=="context" or b["role"].startswith("pad_"):
            address=physical(int(b["base"],16))
            lines += [f"2: AXI Wr Req [0]: addr={address:#x}","AXI Wr Req [0]: strb=0xffffffffffffffff"]
    return "\n".join(lines)+"\n"


class Acceptance(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.folder=Path(self.temp.name)
        self.d=fixture();self.manifest=self.folder/"manifest.json";self.app=self.folder/"app.log";self.trace=self.folder/"trace.log"
        self.app.write_text("DECODER_ATTENTION_REPLAY records=8 diagnostics=0\nMEM_RESERVE: address=0x80000000, size=4096\nATTENTION_TRAFFIC_REPLAY PASSED full_decoder_pass=0\n")
        self.save();self.trace.write_text(trace_for(self.d))
    def save(self): self.manifest.write_text(json.dumps(self.d))
    def run_checker(self,external=False,kernel_elf=None,env=None):
        out=self.folder/("external.json" if external else "dma.json")
        args=[sys.executable,str(FLASH/("check_external_trace.py" if external else "check_dma_trace.py")),
              "--app-log",str(self.app),"--trace",str(self.trace),"--decoder-manifest",str(self.manifest),"--output",str(out)]
        if external: args += ["--dma-audit",str(self.folder/"dma.json")]
        if kernel_elf: args += ["--kernel-elf",str(kernel_elf)]
        return subprocess.run(args,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=env)
    def test_positive_dma_and_external(self):
        self.assertEqual(self.run_checker().returncode,0)
        self.assertEqual(json.loads((self.folder/"dma.json").read_text())["expected_read_bytes"],184320)
        self.assertEqual(self.run_checker(True).returncode,0)
    def test_two_tile_direct_inputs(self):
        self.d=fixture_c256();self.save();self.trace.write_text(trace_for(self.d))
        self.assertEqual(self.run_checker().returncode,0)
        receipt=json.loads((self.folder/"dma.json").read_text())
        self.assertEqual(receipt["expected_read_bytes"],352256)
        self.assertEqual(receipt["expected_gemm_jobs"],32)
        self.assertEqual(self.run_checker(True).returncode,0)
        # A valid first-tile trace cannot substitute for a complete two-tile run.
        first_tile=copy.deepcopy(self.d);first_tile["model"]["past_kv"]=16
        self.trace.write_text(trace_for(first_tile))
        self.assertNotEqual(self.run_checker().returncode,0)
    def test_two_tile_wrong_stride_and_original_input_write(self):
        self.d=fixture_c256();self.save();original=trace_for(self.d)
        base=self.d["records"][0]["attention"]["k_scale_base"]
        # Same byte count but wrong second-tile address must fail.
        wrong=original.replace(f"addr={physical(base+512):#x}",f"addr={physical(base+256):#x}")
        self.trace.write_text(wrong);self.assertNotEqual(self.run_checker().returncode,0)
        weight=self.d["records"][0]["attention"]["v_weight_base"]
        self.trace.write_text(original+f"3: AXI Wr Req [0]: addr={physical(weight):#x}\nAXI Wr Req [0]: strb=0xff\n")
        self.assertEqual(self.run_checker().returncode,0)
        self.assertNotEqual(self.run_checker(True).returncode,0)
    def test_two_tile_completion_and_shape_rejection(self):
        self.d=fixture_c256();self.save()
        records=[dict(index=i,attention=dict(status=1,completed_kv_tiles=2,current_kv_tile=1,dma_sequence=7,
                  sram_copy_bytes=14336,qk_progress_events=16,pv_progress_events=16,total_cycles=50,
                  gemm_submit_cycles=10,gemm_wait_cycles=10,sram_copy_cycles=10,simd_cycles=10)) for i in range(8)]
        path=self.folder/"completion.json"
        data=dict(schema="c4_decoder_attention_completion_v1",full_decoder_pass=False,cycles=500,records=records)
        path.write_text(json.dumps(data));m=DecoderTrafficManifest(self.manifest)
        self.assertEqual(verify_completion(m,path)["phases"]["sram_copy_bytes"],114688)
        records[-1]["attention"]["completed_kv_tiles"]=1;path.write_text(json.dumps(data))
        with self.assertRaises(ValueError):verify_completion(m,path)
        records[-1]["attention"]["completed_kv_tiles"]=2
        self.d["backend"]="resident-fp32"
        for record in self.d["records"]:record["attention"]["output_fp32"]=1
        for record in records:record["attention"]["sram_copy_bytes"]=24576
        self.save();path.write_text(json.dumps(data));m=DecoderTrafficManifest(self.manifest)
        self.assertEqual(verify_completion(m,path)["phases"]["sram_copy_bytes"],196608)
        self.d["model"]["capacity"]=192;self.save()
        with self.assertRaises(ValueError):DecoderTrafficManifest(self.manifest)
    def test_two_tile_c160_key_adapter(self):
        self.d=fixture_c160();self.save();self.trace.write_text(trace_for(self.d))
        m=DecoderTrafficManifest(self.manifest)
        self.assertEqual(len(m.buffers),58);self.assertEqual(m.expected_jobs,32)
        self.assertEqual(self.run_checker().returncode,0)
        self.assertEqual(json.loads((self.folder/"dma.json").read_text())["expected_read_bytes"],352256)
        self.assertEqual(self.run_checker(True).returncode,0)
        # The adapter copies only the compact source, not its larger destination.
        self.d["records"][0]["key_source_bytes"]=16384;self.save()
        with self.assertRaises(ValueError):DecoderTrafficManifest(self.manifest)
    def test_c160_original_inputs_remain_read_only(self):
        self.d=fixture_c160();self.save()
        original=self.d["records"][0]["key_source"]
        self.trace.write_text(trace_for(self.d)+f"3: AXI Wr Req [0]: addr={physical(original):#x}\nAXI Wr Req [0]: strb=0xff\n")
        self.assertEqual(self.run_checker().returncode,0)
        self.assertNotEqual(self.run_checker(True).returncode,0)
    def test_missing_record(self):
        self.d["records"].pop();self.save();self.assertNotEqual(self.run_checker().returncode,0)
    def test_nonobject_manifest_rejected(self):
        for bad in ([], None, dict(schema="c4_decoder_attention_traffic_v1",model=[])):
            with self.subTest(manifest=bad):
                self.manifest.write_text(json.dumps(bad))
                with self.assertRaises(ValueError):DecoderTrafficManifest(self.manifest)
    def check_cpu_input_provenance(self,capacity):
        self.d=fixture_c160() if capacity==160 else fixture_c256()
        snapshot=self.folder/"snapshot";snapshot.mkdir()
        fixture_path=self.folder/"fixture";fixture_path.mkdir()
        source=fixture_path/"reference.npz";source.write_bytes(b"synthetic provenance fixture")
        provenance_path=snapshot/"provenance.json"
        self.d["fixture"]=str(fixture_path)
        self.d["snapshot"]=dict(path=str(snapshot),kind="cpu-fixture-input",provenance=str(provenance_path))
        files=[]
        for b in self.d["buffers"]:
            if b["role"]=="context" or b["role"].startswith("pad_"):continue
            data=bytes(b["bytes"]);(snapshot/(b["name"]+".bin")).write_bytes(data)
            files.append(dict(name=b["name"],bytes=len(data),sha256=hashlib.sha256(data).hexdigest()))
        (snapshot/"buffers.tsv").write_text("synthetic catalog for provenance test\n")
        sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
        provenance=dict(schema="c4_attention_input_provenance_v1",kind="cpu-fixture-input",
            full_decoder_pass=False,model=self.d["model"],snapshot=str(snapshot),fixture=str(fixture_path),
            source_npz=dict(path=str(source),sha256=sha(source)),updated_cache_keys=[f"cache_{i}" for i in range(6)])
        if capacity==160:
            provenance["physical_padding"]=dict(logical_capacity=160,value_execution_rows=256,
                value_zero_rows=[160,256],key_input_bytes=10240,key_adapter_bytes=16384)
        provenance_path.write_text(json.dumps(provenance))
        receipt=dict(kind="cpu-fixture-input",model=self.d["model"],snapshot=str(snapshot),files=files,
            catalog_sha256=sha(snapshot/"buffers.tsv"),snapshot_receipt=str(provenance_path),
            snapshot_receipt_sha256=sha(provenance_path))
        receipt_path=self.folder/"inputs.json";receipt_path.write_text(json.dumps(receipt))
        self.save();m=DecoderTrafficManifest(self.manifest)
        self.assertEqual(verify_inputs(m,receipt_path)["input_kind"],"cpu-fixture-input")
        for kind in (None,"device-snapshot"):
            bad=copy.deepcopy(receipt)
            if kind is None:bad.pop("kind")
            else:bad["kind"]=kind
            receipt_path.write_text(json.dumps(bad))
            with self.assertRaises(ValueError):verify_inputs(m,receipt_path)
        receipt_path.write_text(json.dumps(receipt))
        source.write_bytes(b"substituted initial-cache fixture")
        with self.assertRaises(ValueError):verify_inputs(m,receipt_path)
        source.write_bytes(b"synthetic provenance fixture")
        for key,value in (("updated_cache_keys",["initial_cache"]),("full_decoder_pass",True)):
            bad=copy.deepcopy(provenance);bad[key]=value;provenance_path.write_text(json.dumps(bad))
            receipt["snapshot_receipt_sha256"]=sha(provenance_path);receipt_path.write_text(json.dumps(receipt))
            with self.assertRaises(ValueError):verify_inputs(m,receipt_path)
        if capacity==160:
            bad=copy.deepcopy(provenance);bad["physical_padding"]["value_execution_rows"]=160
            provenance_path.write_text(json.dumps(bad));receipt["snapshot_receipt_sha256"]=sha(provenance_path)
            receipt_path.write_text(json.dumps(receipt))
            with self.assertRaises(ValueError):verify_inputs(m,receipt_path)
    def test_cpu_input_provenance(self):
        self.check_cpu_input_provenance(256)
    def test_c160_cpu_padding_provenance(self):
        self.check_cpu_input_provenance(160)
    def test_tampered_head(self):
        self.d["records"][1]["attention"]["q_base"]-=2048;self.save();self.assertNotEqual(self.run_checker().returncode,0)
    def test_unknown_spill_allocation(self):
        self.d["buffers"].append(dict(name="scores",role="q",base="0xa00000",bytes=4096));self.save()
        self.assertNotEqual(self.run_checker().returncode,0)
    def test_wrong_read_multiplicity(self):
        with self.trace.open("a") as f:f.write(self.trace.read_text().splitlines()[0]+"\n")
        self.assertNotEqual(self.run_checker().returncode,0)
    def test_missing_read_beat(self):
        self.trace.write_text("\n".join(self.trace.read_text().splitlines()[1:])+"\n")
        self.assertNotEqual(self.run_checker().returncode,0)
    def test_gemm_write(self):
        with self.trace.open("a") as f:f.write("gemm:tmem:dma ch=0 AW_FIRE addr=0x0 len=0\n")
        self.assertNotEqual(self.run_checker().returncode,0)
    def test_cpu_input_and_unknown_spill_writes(self):
        for address in (int(self.d["buffers"][0]["base"],16),0xa00000):
            self.trace.write_text(trace_for(self.d)+f"3: AXI Wr Req [0]: addr={physical(address):#x}\nAXI Wr Req [0]: strb=0xff\n")
            self.assertEqual(self.run_checker().returncode,0)
            self.assertNotEqual(self.run_checker(True).returncode,0)
    def test_dispatch_pointer(self):
        with self.trace.open("a") as f:f.write("[TB] REG_WRITE: offset=0x20 value=0x3\n[TB] REG_WRITE: offset=0x24 value=0x900000\n")
        self.assertEqual(self.run_checker().returncode,0);self.assertNotEqual(self.run_checker(True).returncode,0)
    def test_completion_missing_and_wrong_copy(self):
        records=[dict(index=i,attention=dict(status=1,completed_kv_tiles=1,current_kv_tile=0,dma_sequence=4,
                  sram_copy_bytes=8192,qk_progress_events=8,pv_progress_events=8,total_cycles=50,
                  gemm_submit_cycles=10,gemm_wait_cycles=10,sram_copy_cycles=10,simd_cycles=10)) for i in range(8)]
        path=self.folder/"completion.json"
        data=dict(schema="c4_decoder_attention_completion_v1",full_decoder_pass=False,cycles=500,records=records)
        path.write_text(json.dumps(data));m=DecoderTrafficManifest(self.manifest)
        self.assertTrue(verify_completion(m,path)["passed"])
        self.assertEqual(verify_completion(m,path)["outside_attention_intervals"],100)
        # Production online_softmax_worker consumes the resident 128-wide block
        # and records 128/16 progress units even without HBM output events.
        records[-1]["attention"]["qk_progress_events"]=0;path.write_text(json.dumps(data))
        with self.assertRaises(ValueError):verify_completion(m,path)
        records[-1]["attention"]["qk_progress_events"]=8
        data["cycles"]=399;path.write_text(json.dumps(data))
        with self.assertRaises(ValueError):verify_completion(m,path)
        data["cycles"]=500
        records[-1]["attention"]["sram_copy_bytes"]=4096;path.write_text(json.dumps(data))
        with self.assertRaises(ValueError):verify_completion(m,path)
        records.pop();path.write_text(json.dumps(data))
        with self.assertRaises(ValueError):verify_completion(m,path)
    @staticmethod
    def runtime_symbols(base=0x80000000, size=4096):
        end=base+size;start=end-38
        values={"_edata":start,"_end":end,"__bss_start":start,
                "__tbss_size":40,"__tbss_offset":0,"__tdata_size":0}
        symbols={name:dict(value=value,size=0,type="NOTYPE") for name,value in values.items()}
        for name,address,length in (("__warps_per_group",start+2,4),("blockDim",start+6,12),("gridDim",start+22,12)):
            symbols[name]=dict(value=address,size=length,type="OBJECT")
        for name,offset,length in (("__local_group_id",0,4),("threadIdx",8,12),("blockIdx",24,12)):
            symbols[name]=dict(value=offset,size=length,type="TLS")
        return symbols
    def test_runtime_contract_and_byte_boundaries(self):
        symbols=self.runtime_symbols();r=contract(symbols,1,4,16,0x80000000,4096)
        self.assertEqual(r["tls"],(0x80001000,2560))
        line=0x80000fc0;mask=((1<<64)-1)^((1<<26)-1)
        self.assertEqual(write_region(line,mask,r),"runtime_bss")
        self.assertIsNone(write_region(line,mask|(1<<25),r))
        self.assertEqual(write_region(0x800019c0,1<<63,r),"runtime_tls")
        self.assertIsNone(write_region(0x80001a00,1,r))
        with self.assertRaises(ValueError):write_region(line,0,r)
        symbols["score_spill"]=dict(value=0x80000fe8,size=8,type="OBJECT")
        with self.assertRaises(ValueError):contract(symbols,1,4,16,0x80000000,4096)
        symbols=self.runtime_symbols();symbols["__tbss_size"]["value"]=48
        with self.assertRaises(ValueError):contract(symbols,1,4,16,0x80000000,4096)
    def test_write_fifo_drains_and_w_before_aw(self):
        address=physical(int(self.d["buffers"][1]["base"],16))
        extra=f"AXI Wr Req [1]: strb=0xff\n3: AXI Wr Req [1]: addr={address:#x}\n"
        self.trace.write_text(trace_for(self.d)+extra)
        self.assertEqual(self.run_checker().returncode,0)
        self.assertEqual(self.run_checker(True).returncode,0)
        self.trace.write_text(trace_for(self.d)+extra.splitlines()[0]+"\n")
        self.assertEqual(self.run_checker().returncode,0)
        self.assertNotEqual(self.run_checker(True).returncode,0)
        self.trace.write_text(trace_for(self.d)+extra.splitlines()[1]+"\n")
        self.assertEqual(self.run_checker().returncode,0)
        self.assertNotEqual(self.run_checker(True).returncode,0)
    def test_elf_runtime_writes_without_code_whitelist(self):
        # Synthetic readelf output tests the parser/byte-policy integration;
        # the archived real ELF is verified separately against the real trace.
        tool=self.folder/"readelf";lines=[]
        for i,(name,r) in enumerate(self.runtime_symbols().items(),1):
            lines.append(f"{i}: {r['value']:016x} {r['size']} {r['type']} GLOBAL DEFAULT ABS {name}")
        tool.write_text("#!/usr/bin/python3\nprint("+repr("\n".join(lines))+")\n");tool.chmod(0o755)
        elf=self.folder/"kernel.elf";header=bytearray(20);header[:7]=b"\x7fELF\x02\x01\x01";header[18:20]=(243).to_bytes(2,"little");elf.write_bytes(header)
        env=dict(os.environ,PATH=str(self.folder)+os.pathsep+os.environ["PATH"])
        def extra(address,mask):return f"4: AXI Wr Req [0]: addr={physical(address):#x}\nAXI Wr Req [0]: strb={mask:#x}\n"
        good=((1<<64)-1)^((1<<26)-1)
        self.trace.write_text(trace_for(self.d)+extra(0x80000fc0,good)+extra(0x80001000,0xff))
        self.assertEqual(self.run_checker().returncode,0)
        r=self.run_checker(True,elf,env);self.assertEqual(r.returncode,0,r.stderr)
        report=json.loads((self.folder/"external.json").read_text())
        self.assertEqual(report["requests_by_region"]["Wr:runtime_bss"],1)
        self.assertEqual(report["requests_by_region"]["Wr:runtime_tls"],1)
        for address,mask in ((0x80000fc0,good|(1<<25)),(0x80000000,1),(0x80001a00,1)):
            self.trace.write_text(trace_for(self.d)+extra(address,mask))
            self.assertEqual(self.run_checker().returncode,0)
            self.assertNotEqual(self.run_checker(True,elf,env).returncode,0)
    def test_ledger_complete_missing_and_fifo(self):
        lines=[]
        for job in range(16):
            lines.append(f"GEMM_CMD_PERF_SUMMARY | {{job={job}, emitted=2, issued=2, completed=2, incomplete=0, compute_pipeline_cycles=10}}")
            lines.append(f"GEMM_CMD_CLASS_SUMMARY | {{job={job}, class=INPUT, count=2, queue_cycles=2, service_cycles=6}}")
            lines.append(f"GEMM_CMD_CLASS_SUMMARY | {{job={job}, class=UNUSED, count=0, queue_cycles=0, service_cycles=0}}")
            for uid,emit,issue,done in ((0,0,1,4),(1,1,2,5)):
                lines.append(f"GEMM_CMD_TIMELINE | {{job={job}, uid={uid}, child=0, class=INPUT, emit={emit}, issue={issue}, done={done}, queue=1, service=3, overlap_any=2}}")
        path=self.folder/"ledger.log";path.write_text("\n".join(lines)+"\n")
        self.assertEqual(verify_ledger(path,16)["compute_pipeline_active_cycles_total"],160)
        path.write_text("\n".join(line for line in lines if "job=15," not in line)+"\n")
        with self.assertRaises(ValueError):verify_ledger(path,16)
        path.write_text("\n".join(lines).replace("uid=0, child=0", "uid=1, child=0")+"\n")
        with self.assertRaises(ValueError):verify_ledger(path,16)


if __name__ == "__main__": unittest.main()
