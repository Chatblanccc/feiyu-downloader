#!/usr/bin/env python3
"""Build a persistently signed internal APK. Signing secrets never enter the repo."""
from pathlib import Path
import argparse, hashlib, json, os, secrets, shutil, subprocess, zipfile
ROOT=Path(__file__).resolve().parents[1]
def main():
    parser=argparse.ArgumentParser();parser.add_argument("--version-code",default="2");parser.add_argument("--verify",action="store_true");parser.add_argument("--include-device-tests",action="store_true");args=parser.parse_args()
    env=os.environ.copy();java=env.get("JAVA_HOME")
    if not java:
        homes=sorted((ROOT.parent/"work/android-toolchain").glob("jdk-*/Contents/Home"))
        if homes:java=str(homes[-1])
    if not java:raise SystemExit("Set JAVA_HOME to a JDK 21 installation.")
    env["JAVA_HOME"]=java
    env.setdefault("GRADLE_USER_HOME",str(ROOT.parent/"work/android-toolchain/gradle-cache"))
    signing=Path.home()/".local/share/feiyu-android/signing";signing.mkdir(parents=True,exist_ok=True);signing.chmod(0o700)
    key=signing/"internal.jks";credentials=signing/"internal-signing.json"
    if key.exists()!=credentials.exists():raise SystemExit("Incomplete existing signing configuration; restore the matching key and credentials. Nothing was overwritten.")
    if not key.exists():
        private={"storePassword":secrets.token_urlsafe(32),"keyPassword":secrets.token_urlsafe(32)}
        env["FEIYU_ANDROID_STORE_PASSWORD"]=private["storePassword"];env["FEIYU_ANDROID_KEY_PASSWORD"]=private["keyPassword"]
        subprocess.run([str(Path(java)/"bin/keytool"),"-genkeypair","-keystore",str(key),"-storetype","JKS","-alias","feiyu-internal","-keyalg","RSA","-keysize","4096","-sigalg","SHA256withRSA","-validity","10000","-dname","CN=Feiyu Internal, OU=Android, O=Feiyu, C=CN","-storepass:env","FEIYU_ANDROID_STORE_PASSWORD","-keypass:env","FEIYU_ANDROID_KEY_PASSWORD"],env=env,check=True)
        key.chmod(0o600);credentials.write_text(json.dumps(private));credentials.chmod(0o600)
    else:private=json.loads(credentials.read_text())
    env.update(FEIYU_ANDROID_KEYSTORE=str(key),FEIYU_ANDROID_STORE_PASSWORD=private["storePassword"],FEIYU_ANDROID_KEY_PASSWORD=private["keyPassword"])
    subprocess.run(["python3",str(ROOT/"scripts/fetch_runtime.py")],check=True)
    local=ROOT.parent/"work/android-toolchain/gradle-8.13/bin/gradle"
    command=[str(local if local.exists() else ROOT/"gradlew"),"-p",str(ROOT),f"-PfeiyuVersionCode={args.version_code}",":app:assembleRelease","--console=plain"]
    if args.verify:command+= [":app:testDebugUnitTest",":app:lintRelease"]
    if args.include_device_tests:command+= [":app:assembleDebug",":app:assembleDebugAndroidTest"]
    subprocess.run(command,env=env,check=True)
    out=ROOT.parent/"outputs/android";out.mkdir(parents=True,exist_ok=True)
    apk=out/"FeiyuDownload-0.1.0-alpha02-Android-arm64.apk"
    shutil.copy2(ROOT/"app/build/outputs/apk/release/app-release.apk",apk)
    archive=out/"FeiyuDownload-0.1.0-alpha02-Android-Source.zip"
    try:
        source_paths=[ROOT/name for name in subprocess.check_output(["git","-C",str(ROOT),"ls-files","-z","--cached","--others","--exclude-standard","--","."],text=True).split("\0") if name]
    except subprocess.CalledProcessError:
        source_paths=list(ROOT.rglob("*"))
    with zipfile.ZipFile(archive,"w",zipfile.ZIP_DEFLATED) as z:
        for path in sorted(source_paths):
            if not path.is_file():continue
            relative=path.relative_to(ROOT)
            if any(part in {"build",".gradle",".kotlin","jniLibs","__pycache__",".git"} for part in relative.parts) or "assets/runtime" in str(relative) or path.name in {"local.properties",".DS_Store","internal-signing.json"}:continue
            if path.suffix in {".jks",".keystore",".pyc"} or path.name==".env" or path.name.startswith(".env."):continue
            z.write(path,Path("AndroidDownloader")/relative)
    (out/"SHA256SUMS.txt").write_text("".join(hashlib.sha256(p.read_bytes()).hexdigest()+"  "+p.name+"\n" for p in [apk,archive]))
    (out/"Android使用说明.md").write_text((ROOT/"README.md").read_text().replace("(docs/验收报告.md)","(验收报告.md)").replace("(docs/THIRD_PARTY.md)","(THIRD_PARTY.md)"))
    shutil.copy2(ROOT/"LICENSE",out/"LICENSE")
    shutil.copy2(ROOT/"docs/THIRD_PARTY.md",out/"THIRD_PARTY.md")
    report=ROOT/"docs/验收报告.md"
    if report.exists():shutil.copy2(report,out/report.name)
    print("Internal APK:",apk)
    print("Source archive:",archive)
    print("Signing key is stored separately in:",signing)
if __name__=="__main__":main()
