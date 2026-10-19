#!/usr/bin/env python3
"""Normalize SDK 37.0 legacy metadata for the pinned AGP without changing android.jar."""
from pathlib import Path
import sys


def main():
    SDK = Path(sys.argv[1])
    platform=SDK/"platforms/android-37.0"
    # SDK 37.0's ZIP uses a decimal legacy ApiLevel property. Keep android.jar
    # byte-for-byte intact, normalize only legacy metadata for sdklib 8.13.
    properties=platform/"source.properties";properties.write_text(properties.read_text().replace("AndroidVersion.ApiLevel=37.0","AndroidVersion.ApiLevel=37"))
    (platform/"package.xml").write_text('''<?xml version="1.0"?><ns2:repository xmlns:ns2="http://schemas.android.com/repository/android/common/02" xmlns:ns5="http://schemas.android.com/sdk/android/repo/repository2/03" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><license id="android-sdk-license" type="text">Android SDK license: https://developer.android.com/studio/terms</license><localPackage path="platforms;android-37.0" obsolete="false"><type-details xsi:type="ns5:platformDetailsType"><api-level>37</api-level><extension-level>22</extension-level><base-extension>true</base-extension><layoutlib api="15"/></type-details><revision><major>2</major></revision><display-name>Android SDK Platform 37.0</display-name><uses-license ref="android-sdk-license"/></localPackage></ns2:repository>''')


if __name__ == "__main__":
    main()
