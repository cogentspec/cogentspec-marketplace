"""Build the public, credential-free Qwen Web companion source bundle."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
source = Path(__file__).resolve().parents[1] / "qwen-web-extension"
files = ["manifest.json", "policy.mjs", "worker.mjs", "command.js", "NativeHost.cs", "register-native-host.ps1", "README.md"]
if args.output.suffix != ".zip":
    parser.error("Output must be a ZIP source bundle.")
args.output.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(args.output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for filename in sorted(files):
        # Fixed public source files only; never include inspection downloads,
        # compiled binaries, tests, registration files, logs or credentials.
        info = zipfile.ZipInfo(filename, (1980, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        archive.writestr(info, (source / filename).read_text(encoding="utf-8").replace("\r\n", "\n").encode("utf-8"))
print(json.dumps({"files": len(files), "bytes": args.output.stat().st_size,
                  "sha256": hashlib.sha256(args.output.read_bytes()).hexdigest()}))
