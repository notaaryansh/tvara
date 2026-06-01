#!/usr/bin/env python3
# Reads a text query from argv, outputs 77 BPE token IDs as JSON to stdout.
# Used by the Swift indexer/search at query time.
import sys, json
from transformers import CLIPTokenizer

_tok = None
def tok():
    global _tok
    if _tok is None:
        _tok = CLIPTokenizer.from_pretrained("openai/clip-vit-base-patch32")
    return _tok

if __name__ == "__main__":
    text = " ".join(sys.argv[1:])
    # Get bare token IDs (BOS + tokens + EOS), no padding
    raw = tok()(text, truncation=True, max_length=77, return_tensors="pt")["input_ids"][0].tolist()
    # Apple MobileCLIP wants zero-padding (not EOS-padding) after the trailing EOS.
    ids = raw + [0] * (77 - len(raw))
    print(json.dumps(ids))
