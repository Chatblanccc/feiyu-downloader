#!/usr/bin/env python3
"""Verify packaged runtime hashes and all ELF alignments, including nested ZIPs."""
from pathlib import Path
import argparse,hashlib,io,json,subprocess,zipfile
from fetch_runtime import elf_report
def main():
    parser=argparse.ArgumentParser();parser.add_argument("apk",type=Path);parser.add_argument("--sdk",type=Path);args=parser.parse_args()
    reports=[]
    with zipfile.ZipFile(args.apk) as apk:
        manifest=json.loads(apk.read("assets/runtime/manifest.json"))
        assert hashlib.sha256(apk.read("assets/runtime/yt-dlp")).hexdigest()==manifest["ytDlpSha256"]
        for name,expected in manifest["files"].items():assert hashlib.sha256(apk.read("lib/arm64-v8a/"+name)).hexdigest()==expected,name
        for name in apk.namelist():
            if not name.startswith("lib/") or not name.endswith(".so"):continue
            assert name.startswith("lib/arm64-v8a/"),"Unexpected ABI"
            data=apk.read(name)
            if zipfile.is_zipfile(io.BytesIO(data)):
                with zipfile.ZipFile(io.BytesIO(data)) as nested:
                    for item in nested.infolist():
                        if not item.is_dir():
                            report=elf_report(name+"/"+item.filename,nested.read(item))
                            if report:reports.append(report)
            else:
                report=elf_report(name,data)
                if report:reports.append(report)
        assert reports and all(x["compatible16KB"] for x in reports)
    result={"apk":args.apk.name,"sha256":hashlib.sha256(args.apk.read_bytes()).hexdigest(),"bytes":args.apk.stat().st_size,"elfCount":len(reports),"allELF16KB":True,"runtimeHashes":True}
    if args.sdk:
        tools=args.sdk/"build-tools/37.0.0"
        subprocess.run([str(tools/"zipalign"),"-c","-P","16","4",str(args.apk)],check=True)
        signer=subprocess.run([str(tools/"apksigner"),"verify","--verbose","--print-certs",str(args.apk)],check=True,text=True,stdout=subprocess.PIPE)
        result["signatureVerification"]=signer.stdout
    target=args.apk.with_suffix(".verification.json");target.write_text(json.dumps(result,indent=2)+"\n")
    print(json.dumps({k:v for k,v in result.items() if k!="signatureVerification"},indent=2))
if __name__=="__main__":main()
