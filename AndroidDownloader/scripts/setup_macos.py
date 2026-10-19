#!/usr/bin/env python3
"""Install a checksum-locked, workspace-local macOS ARM64 build toolchain."""
from pathlib import Path
import concurrent.futures, hashlib, os, shutil, subprocess, tarfile, zipfile
ROOT=Path(__file__).resolve().parents[1];BASE=ROOT.parent/"work/android-toolchain";SDK=BASE/"sdk"
PACKAGES=[
 ("jdk.tar.gz","https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.12.1%2B1/OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.12.1_1.tar.gz","3623232f33a9c3baadf304480b2535f9a3cba8a58d42ecbb438ba267315d9998","sha256",None),
 ("gradle-clean.zip","https://downloads.gradle.org/distributions/gradle-8.13-bin.zip","20f1b1176237254a6fc204d8434196fa11a4cfb387567519c61556e8710aed78","sha256",None),
 ("platform-mirror.zip","platform-37.0_r02.zip","ed8ebf7f8822a4de5686d427f237d2fa30ff7410","sha1","platforms/android-37.0"),
 ("build-tools-mirror.zip","build-tools_r37_macosx.zip","eb080751b2b2028eb3604f571027d6f7b3c46321","sha1","build-tools/37.0.0"),
 ("platform-tools-mirror.zip","platform-tools_r37.0.1-darwin.zip","6ae73f4de6452dc57e62ec02b68eed92a4c21661","sha1","platform-tools"),
 ("commandline-mirror.zip","commandlinetools-mac_arm64-16111833_latest.zip","ad03dc49bfacfd52c110b14104ea548b8a07e830","sha1","cmdline-tools/latest"),
]
def install(item):
    name,source,checksum,algorithm,dest=item;path=BASE/name
    def valid():return path.is_file() and hashlib.new(algorithm,path.read_bytes()).hexdigest()==checksum
    if not valid():
        urls=[source] if source.startswith("https:") else ["https://mirrors.cloud.tencent.com/AndroidSDK/"+source,"https://dl.google.com/android/repository/"+source]
        for url in urls:
            candidate=path.with_suffix(".setup-part")
            r=subprocess.run(["curl","--fail","--location","--silent","--show-error","--max-time","300","--retry","2","-o",str(candidate),url])
            if r.returncode==0 and hashlib.new(algorithm,candidate.read_bytes()).hexdigest()==checksum:candidate.replace(path);break
        assert valid(),"Download or checksum failed: "+name
    print("verified",name,flush=True)
    target=SDK/dest if dest else BASE/("jdk-21.0.12.1+1" if name.startswith("jdk") else "gradle-8.13")
    marker=target/"source.properties" if dest else target/("Contents/Home/bin/java" if name.startswith("jdk") else "bin/gradle")
    if marker.exists():return
    stage=BASE/("setup-"+name);stage.mkdir(exist_ok=True)
    if name.endswith(".tar.gz"):
        with tarfile.open(path) as archive:
            for member in archive.getmembers():assert (stage/member.name).resolve().is_relative_to(stage.resolve())
            archive.extractall(stage)
    else:
        with zipfile.ZipFile(path) as archive:
            for member in archive.infolist():assert (stage/member.filename).resolve().is_relative_to(stage.resolve())
            archive.extractall(stage)
            for member in archive.infolist():
                if member.external_attr>>16&0o111:os.chmod(stage/member.filename,0o755)
    child=next(stage.iterdir());target.parent.mkdir(parents=True,exist_ok=True)
    if target.exists():assert not any(target.iterdir()),"Existing incomplete SDK directory: "+str(target);target.rmdir()
    shutil.move(str(child),target);stage.rmdir()
def main():
    assert os.uname().sysname=="Darwin" and os.uname().machine=="arm64","This helper is for macOS ARM64. Other hosts may use their own SDK/JDK."
    BASE.mkdir(parents=True,exist_ok=True);SDK.mkdir(exist_ok=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:list(pool.map(install,PACKAGES))
    platform=SDK/"platforms/android-37.0"
    # SDK 37.0's ZIP uses a decimal legacy ApiLevel property. Keep android.jar
    # byte-for-byte intact, normalize only legacy metadata for sdklib 8.13.
    properties=platform/"source.properties";properties.write_text(properties.read_text().replace("AndroidVersion.ApiLevel=37.0","AndroidVersion.ApiLevel=37"))
    (platform/"package.xml").write_text('''<?xml version="1.0"?><ns2:repository xmlns:ns2="http://schemas.android.com/repository/android/common/02" xmlns:ns5="http://schemas.android.com/sdk/android/repo/repository2/03" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><license id="android-sdk-license" type="text">Android SDK license: https://developer.android.com/studio/terms</license><localPackage path="platforms;android-37.0" obsolete="false"><type-details xsi:type="ns5:platformDetailsType"><api-level>37</api-level><extension-level>22</extension-level><base-extension>true</base-extension><layoutlib api="15"/></type-details><revision><major>2</major></revision><display-name>Android SDK Platform 37.0</display-name><uses-license ref="android-sdk-license"/></localPackage></ns2:repository>''')
    licenses=SDK/"licenses";licenses.mkdir(exist_ok=True);(licenses/"android-sdk-license").write_text("24333f8a63b6825ea9c5514f83c2829b004d1fee\n")
    (ROOT/"local.properties").write_text("sdk.dir="+str(SDK)+"\n")
    print("Workspace toolchain ready; no global Java or Android installation was changed.")
if __name__=="__main__":main()
