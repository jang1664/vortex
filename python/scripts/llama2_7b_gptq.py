#!/usr/bin/env python3
"""
Llama-2-7B with Vortex acceleration
Usage: python llama2_7b_gptq.py
"""

# Import and patch BEFORE loading transformers model
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
sys.path.insert(0, os.path.dirname(__file__))

import vortex_torch as vx
from vortex_llama import patch_transformers_llama

# Patch transformers with Vortex kernels
patch_transformers_llama()

# Now import and use transformers normally
from transformers import AutoModelForCausalLM, AutoTokenizer

print("Loading model...")
model_name_or_path = "TheBloke/Llama-2-7B-GPTQ"
model = AutoModelForCausalLM.from_pretrained(
    model_name_or_path,
    device_map="auto",
    trust_remote_code=True,
    revision="main"
)

tokenizer = AutoTokenizer.from_pretrained(model_name_or_path, use_fast=True)

prompt = "Tell me about AI"
prompt_template = f'''{prompt}

'''

print("\n*** Generate:")

input_ids = tokenizer(prompt_template, return_tensors='pt').input_ids
output = model.generate(
    inputs=input_ids, 
    temperature=0.7, 
    do_sample=True, 
    top_p=0.95, 
    top_k=40, 
    max_new_tokens=2
)
print(tokenizer.decode(output[0]))
