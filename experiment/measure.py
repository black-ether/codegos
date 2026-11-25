"""Run from the experiment branch root after building both executables."""
import json
import subprocess
from pathlib import Path

research = Path("../../retrieval-research/checkouts")
files = [research/"powerpath/pp.ps1", research/"task-full/call.go",
         research/"task-full/task.go", *Path("experiment/fixtures").glob("sample.*")]
for file in files:
    for version in ("baseline", "experimental"):
        exe = Path("experiment/bin") / (version + ".exe")
        def read(*args):
            return json.loads(subprocess.check_output([exe, file, *args, "--json"]))
        rows = []
        def visit(nodes, parent=None):
            for node in nodes:
                rows.append(dict(parent=parent, **{k:v for k,v in node.items() if k!="source"}))
                if node["child_count"]:
                    visit(read("go", str(node["start_line"]))["children"], node["start_line"])
        visit(read()["headings"])
        Path(f"experiment/raw/{file.name}-{version}.json").write_text(json.dumps(rows, indent=1)+"\n")
        if version == "experimental" and file.suffix in (".go", ".py"):
            reference = Path(f"experiment/raw/{file.name}-baseline.json")
            assert rows == json.loads(reference.read_text()), file

powerpath = research/"powerpath/pp.ps1"
for version, steps in {"baseline": [191,494,2453,2560], "experimental":[191,2453]}.items():
    exe = Path("experiment/bin")/(version+".exe")
    for step in steps:
        data = subprocess.check_output([exe,powerpath,"go",str(step),"--plain"])
        if step in (494,191) and (version=="experimental" or step==494):
            assert b"2453" in data
        print(version,step,len(data))
    if version=="experimental":
        hint=subprocess.check_output([exe,powerpath,"tail"]).decode().split()[-1]
        assert b"Show-Help" in subprocess.check_output([exe,powerpath,"show",hint])
