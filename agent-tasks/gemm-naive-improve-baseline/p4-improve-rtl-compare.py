#!/usr/bin/env python3
"""Compare complete elaborated XML logic and hierarchy, ignoring source loc only."""
import hashlib,json,xml.etree.ElementTree as ET
from pathlib import Path
TASK=Path(__file__).resolve().parent
OUT=TASK/'p4-improve-rtl'
records=[]
for mxu in (16,32):
 trees={}; stats={}; hashes={}
 for revision in ('baseline','candidate'):
  path=OUT/f'{revision}{mxu}-iteration3/design.xml'
  hashes[revision]=hashlib.sha256(path.read_bytes()).hexdigest()
  root=ET.parse(path).getroot()
  # File tables are provenance only. Keep all cells and complete netlist AST.
  selected=ET.Element('elaborated_design')
  for tag in ('cells','netlist'): selected.append(root.find(tag))
  for e in selected.iter():
   e.attrib.pop('loc',None)
   # XML pretty-print whitespace is not AST data.
   if e.text is not None and not e.text.strip(): e.text=None
   if e.tail is not None and not e.tail.strip(): e.tail=None
  trees[revision]=selected
  stats[revision]={'ast_elements':sum(1 for _ in selected.iter()),'cells':sum(1 for _ in selected.iter('cell')),'modules':sum(1 for _ in selected.iter('module')),'variables':sum(1 for _ in selected.iter('var'))}
 canonical={k:ET.tostring(v) for k,v in trees.items()}
 equal=canonical['baseline']==canonical['candidate']
 mismatches=[]
 if not equal:
  left=list(trees['baseline'].iter());right=list(trees['candidate'].iter())
  for index,(a,b) in enumerate(zip(left,right)):
   if (a.tag,a.attrib,a.text)!=(b.tag,b.attrib,b.text):
    mismatches.append({'index':index,'baseline':[a.tag,a.attrib,a.text],'candidate':[b.tag,b.attrib,b.text]})
    if len(mismatches)==12: break
 records.append(dict(mxu=mxu,equal=equal,stats=stats,raw_xml_sha256=hashes,canonical_sha256={k:hashlib.sha256(v).hexdigest() for k,v in canonical.items()},first_mismatches=mismatches))
report={'status':'pass' if all(r['equal'] for r in records) else 'fail','scope':'Full improve GEMM-node elaborated hierarchy and logic AST, MXU16/32; no synthesis; vendor bodies opaque','normalization':'Remove file provenance tables and loc attributes, strip XML indentation only. Preserve all semantic nodes, values, widths, IDs, references, and names.','records':records}
(OUT/'comparison.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2)); raise SystemExit(0 if report['status']=='pass' else 1)
