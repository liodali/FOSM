#!/usr/bin/env python3
"""Generate an isolated iOS benchmark project; never modify the Swift package."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def git(package, *args):
    return subprocess.check_output(["git", "-C", str(package), *args], text=True).strip()


def prepare(package, output):
    example = Path(__file__).resolve().parents[1]
    sources = example / "native_mapcore"
    contract = example / "benchmark/native_comparison.json"
    lock_path = package / "Package.resolved"
    lock = json.loads(lock_path.read_text())
    pin = next(p for p in lock["pins"] if p["identity"] == "maps-core")
    digest = hashlib.sha256()
    for path in sorted((package / "Sources").rglob("*")):
        if path.is_file():
            digest.update(str(path.relative_to(package)).encode() + b"\0")
            digest.update(path.read_bytes())
    identity = {
        "wrapperRevision": git(package, "rev-parse", "HEAD"),
        "wrapperDirty": bool(git(package, "status", "--porcelain")),
        "wrapperSourceSha256": digest.hexdigest(),
        "expectedMapCorePin": pin,
        "contractSha256": hashlib.sha256(contract.read_bytes()).hexdigest(),
    }
    output.mkdir(parents=True, exist_ok=True)
    identity_path = output / "source_identity.json"
    identity_path.write_text(json.dumps(identity, indent=2) + "\n")
    project = output / "MapCoreComparison.xcodeproj"
    project.mkdir(exist_ok=True)
    lock_destination = project / "project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    lock_destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(lock_path, lock_destination)

    # OpenStep plist serialization keeps paths with spaces properly quoted.
    objects = {}

    class Ref(str):
        pass

    def obj(isa, **fields):
        ref = Ref(f"{len(objects) + 1:024X}")
        objects[ref] = {"isa": isa, **fields}
        return ref

    def file(path, kind):
        return obj("PBXFileReference", lastKnownFileType=kind,
                   path=str(path), sourceTree="<absolute>")

    swift = [file(sources / name, "sourcecode.swift") for name in
             ["ComparisonWorkload.swift", "ComparisonApp.swift"]]
    resources = [file(contract, "text.json"), file(identity_path, "text.json")]
    info = file(sources / "Info.plist", "text.plist.xml")
    product = obj("PBXFileReference", explicitFileType="wrapper.application",
                  path="MapCoreComparison.app", sourceTree="BUILT_PRODUCTS_DIR")
    products = obj("PBXGroup", children=[product], name="Products", sourceTree="<group>")
    group = obj("PBXGroup", children=[*swift, *resources, info, products], sourceTree="<group>")
    package_ref = obj("XCLocalSwiftPackageReference", relativePath=str(package))
    dependency = obj("XCSwiftPackageProductDependency", package=package_ref,
                     productName="OSMFlutterFramework")
    source_phase = obj("PBXSourcesBuildPhase", buildActionMask=2147483647,
                       files=[obj("PBXBuildFile", fileRef=f) for f in swift],
                       runOnlyForDeploymentPostprocessing=0)
    resource_phase = obj("PBXResourcesBuildPhase", buildActionMask=2147483647,
                         files=[obj("PBXBuildFile", fileRef=f) for f in resources],
                         runOnlyForDeploymentPostprocessing=0)
    framework_phase = obj("PBXFrameworksBuildPhase", buildActionMask=2147483647,
                          files=[obj("PBXBuildFile", productRef=dependency)],
                          runOnlyForDeploymentPostprocessing=0)
    settings = {
        "SDKROOT": "iphoneos", "IPHONEOS_DEPLOYMENT_TARGET": "16.0",
        "SWIFT_VERSION": "5.0", "CLANG_ENABLE_MODULES": "YES",
        "PRODUCT_BUNDLE_IDENTIFIER": "dev.fosm.MapCoreComparison",
        "PRODUCT_NAME": "$(TARGET_NAME)", "TARGETED_DEVICE_FAMILY": "1,2",
        "INFOPLIST_FILE": str(sources / "Info.plist"), "CODE_SIGN_STYLE": "Automatic",
    }

    def configs(target):
        values = []
        for name in ["Debug", "Release"]:
            config = dict(settings) if target else {}
            config["SWIFT_OPTIMIZATION_LEVEL"] = "-O" if name == "Release" else "-Onone"
            values.append(obj("XCBuildConfiguration", name=name, buildSettings=config))
        return obj("XCConfigurationList", buildConfigurations=values,
                   defaultConfigurationIsVisible=0, defaultConfigurationName="Release")

    target = obj("PBXNativeTarget", name="MapCoreComparison", productName="MapCoreComparison",
                 buildConfigurationList=configs(True), buildPhases=[source_phase, framework_phase, resource_phase],
                 buildRules=[], dependencies=[], packageProductDependencies=[dependency],
                 productReference=product, productType="com.apple.product-type.application")
    root = obj("PBXProject", attributes={"LastUpgradeCheck": "2650"},
               buildConfigurationList=configs(False), compatibilityVersion="Xcode 14.0",
               developmentRegion="en", hasScannedForEncodings=0, knownRegions=["en", "Base"],
               mainGroup=group, productRefGroup=products, projectDirPath="", projectRoot="",
               packageReferences=[package_ref], targets=[target])

    def plist(value):
        if isinstance(value, Ref):
            return str(value)
        if isinstance(value, dict):
            return "{\n" + "\n".join(f"{json.dumps(str(k))} = {plist(v)};" for k, v in value.items()) + "\n}"
        if isinstance(value, list):
            return "(" + ", ".join(plist(v) for v in value) + ")"
        return str(value) if isinstance(value, int) else json.dumps(value)

    (project / "project.pbxproj").write_text("// !$*UTF8*$!\n" + plist({
        "archiveVersion": 1, "classes": {}, "objectVersion": 56,
        "objects": objects, "rootObject": root,
    }) + "\n")
    print(project)
    print(json.dumps(identity, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    prepare(args.package.resolve(strict=True), args.output.resolve())
