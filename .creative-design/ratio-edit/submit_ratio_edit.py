# -*- coding: utf-8 -*-
import json, re, subprocess, sys
from pathlib import Path

WORKDIR = Path(__file__).resolve().parent
WS = "cws_60496849351348994"
CLI = ["design-cli"]

def run(argv, payload=None, label=""):
    proc = subprocess.run(argv, input=payload, shell=False, cwd=WORKDIR,
                           capture_output=True, timeout=120)
    (WORKDIR / f"{label}.stdout.bin").write_bytes(proc.stdout)
    (WORKDIR / f"{label}.stderr.bin").write_bytes(proc.stderr)
    (WORKDIR / f"{label}.exitcode.txt").write_text(str(proc.returncode), encoding="utf-8")
    if proc.returncode != 0:
        raise SystemExit(f"[{label}] exit {proc.returncode}: {proc.stderr.decode('utf-8', 'replace')}")
    resp = json.loads(proc.stdout.decode("utf-8", errors="strict"))
    if resp.get("code") != 0:
        raise SystemExit(f"[{label}] resp code={resp.get('code')} msg={resp.get('msg')}")
    return resp.get("xml_data")

def create(xml_text, label):
    payload = xml_text.encode("utf-8")
    argv = CLI + ["design-workspace", "+create", "--canvas-workspace-id", WS, "--input", "-"]
    xml_data = run(argv, payload=payload, label=label)
    m = re.search(r'<item\s+item_id="(\d+)"', xml_data)
    if not m:
        raise SystemExit(f"[{label}] 未解析到 item_id: {xml_data}")
    return m.group(1), xml_data

# 1. 锚点（用户原图）
anchor_xml = (WORKDIR / "anchor.xml").read_text(encoding="utf-8")
anchor_id, anchor_xml_data = create(anchor_xml, "anchor-create")
print("ANCHOR_ID=", anchor_id)

# 2. 编辑结果，血缘指向锚点
result_xml = (WORKDIR / "result_template.xml").read_text(encoding="utf-8").replace("ANCHOR_ID", anchor_id)
result_id, result_xml_data = create(result_xml, "result-create")
print("RESULT_ID=", result_id)

# 3. +get 回读两个对象
argv = CLI + ["design-workspace", "+get", "--canvas-workspace-id", WS,
              "--item-ids", anchor_id, "--item-ids", result_id]
get_xml = run(argv, label="get-both")
print("=== GET ===")
print(get_xml)

# 4. 校验回读 URL 与原始短链逐字一致
checks = [
    (anchor_id, "https://aka.doubaocdn.com/s/3NH62d86SY"),
    (result_id, "https://aka.doubaocdn.com/s/mmMwntlcq8"),
]
for iid, expect in checks:
    block = re.search(rf'<item[^>]*item_id="{iid}".*?</item>', get_xml, re.S)
    if not block:
        raise SystemExit(f"回读缺少 item {iid}")
    url = re.search(r'<asset\s+url="([^"]+)"', block.group(0))
    actual = url.group(1) if url else None
    ok = actual == expect
    print(f"CHECK {iid}: url_match={ok} actual={actual}")
    if not ok:
        raise SystemExit(f"URL 不一致 for {iid}")
print("ALL_OK")
