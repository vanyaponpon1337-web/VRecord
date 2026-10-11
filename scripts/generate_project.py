"""Deterministically generate the checked-in, dependency-free Xcode project."""
from pathlib import Path
import hashlib
import json
import struct
import zlib

root = Path(__file__).resolve().parent.parent
assets = root / 'VRecord/Resources/Assets.xcassets'
iconset = assets / 'AppIcon.appiconset'
iconset.mkdir(parents=True, exist_ok=True)
(assets / 'Contents.json').write_text(json.dumps({'info': {'author': 'xcode', 'version': 1}}))
color = assets / 'LaunchBackground.colorset'
color.mkdir(exist_ok=True)
(color / 'Contents.json').write_text(json.dumps({'colors': [{'idiom': 'universal', 'color': {'color-space': 'srgb', 'components': {'red':'0','green':'0','blue':'0','alpha':'1'}}}], 'info': {'author':'xcode','version':1}}))
# Opaque native app icon: two camera lenses and a red recording light.
size = 1024
rows = bytearray()
for y in range(size):
    rows.append(0)
    for x in range(size):
        rgb = (12, 17, 24)
        for cx in (310, 714):
            d = (x-cx)**2 + (y-525)**2
            if d < 178**2: rgb = (235, 240, 246)
            if d < 153**2: rgb = (22, 32, 48)
            if d < 110**2: rgb = (27, 86, 112)
            if d < 65**2: rgb = (8, 20, 32)
            if (x-(cx-35))**2 + (y-490)**2 < 23**2: rgb = (120, 205, 218)
        if (x-820)**2 + (y-238)**2 < 35**2: rgb = (255, 35, 45)
        rows.extend(rgb)
def chunk(kind, data):
    return struct.pack('>I',len(data)) + kind + data + struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR',struct.pack('>IIBBBBB',size,size,8,2,0,0,0)) + chunk(b'IDAT',zlib.compress(rows,9)) + chunk(b'IEND',b'')
(iconset / 'AppIcon.png').write_bytes(png)
(iconset / 'Contents.json').write_text(json.dumps({'images':[{'filename':'AppIcon.png','idiom':'universal','platform':'ios','size':'1024x1024'}],'info':{'author':'xcode','version':1}}))

def uid(value): return hashlib.sha1(value.encode()).hexdigest()[:24].upper()
def q(value): return json.dumps(str(value))
objects = []
def add(key, value): objects.append(f'{uid(key)} = {{ {value} }};')
source = sorted((root / 'VRecord').rglob('*.swift')) + sorted((root / 'VRecord').rglob('*.metal'))
paths = [p.relative_to(root).as_posix() for p in source]
paths += ['VRecord/Resources/Assets.xcassets','VRecord/Resources/Info.plist']
source_ids, resource_ids = [], []
for path in paths:
    ext = Path(path).suffix
    kind = {'.swift':'sourcecode.swift','.metal':'sourcecode.metal','.xcassets':'folder.assetcatalog','.plist':'text.plist.xml'}[ext]
    add('file:'+path, f'isa = PBXFileReference; lastKnownFileType = {kind}; path = {q(path)}; sourceTree = "<group>";')
    if ext != '.plist':
        add('build:'+path, f'isa = PBXBuildFile; fileRef = {uid("file:"+path)};')
        (resource_ids if ext == '.xcassets' else source_ids).append(uid('build:'+path))
add('product', 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = VRecord.app; sourceTree = BUILT_PRODUCTS_DIR;')
add('mainGroup', 'isa = PBXGroup; children = (' + ','.join(uid('file:'+p) for p in paths) + ','+uid('productsGroup')+'); sourceTree = "<group>";')
add('productsGroup', f'isa = PBXGroup; children = ({uid("product")}); name = Products; sourceTree = "<group>";')
add('sources', 'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ('+','.join(source_ids)+'); runOnlyForDeploymentPostprocessing = 0;')
add('resources', 'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ('+','.join(resource_ids)+'); runOnlyForDeploymentPostprocessing = 0;')
add('frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
for level in ('Debug','Release'):
    project_settings = {
        'CLANG_ENABLE_MODULES':'YES','SDKROOT':'iphoneos','IPHONEOS_DEPLOYMENT_TARGET':'18.5',
        'SWIFT_VERSION':'5.0','ENABLE_STRICT_OBJC_MSGSEND':'YES','CLANG_ENABLE_OBJC_ARC':'YES',
        'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if level == 'Debug' else '-O',
        'DEBUG_INFORMATION_FORMAT':'dwarf' if level == 'Debug' else 'dwarf-with-dsym',
        'GCC_OPTIMIZATION_LEVEL':'0' if level == 'Debug' else 's',
        'MTL_ENABLE_DEBUG_INFO':'INCLUDE_SOURCE' if level == 'Debug' else 'NO',
        'ENABLE_TESTABILITY':'YES' if level == 'Debug' else 'NO',
        'SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG' if level == 'Debug' else '',
    }
    target_settings = {
        'PRODUCT_NAME':'VRecord','PRODUCT_BUNDLE_IDENTIFIER':'com.vrecord.app',
        'INFOPLIST_FILE':'VRecord/Resources/Info.plist','GENERATE_INFOPLIST_FILE':'NO',
        'TARGETED_DEVICE_FAMILY':'1','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator',
        'SUPPORTS_MACCATALYST':'NO','SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD':'NO',
        'ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon','CODE_SIGNING_ALLOWED':'NO',
        'CODE_SIGNING_REQUIRED':'NO','CODE_SIGN_IDENTITY':'','ARCHS':'arm64',
        'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks',
        'SWIFT_EMIT_LOC_STRINGS':'NO','ENABLE_USER_SCRIPT_SANDBOXING':'YES',
        'CURRENT_PROJECT_VERSION':'1','MARKETING_VERSION':'1.0',
    }
    for category, settings in [('project',project_settings),('target',target_settings)]:
        add(category+level, 'isa = XCBuildConfiguration; buildSettings = {' + ' '.join(f'{k} = {q(v)};' for k,v in settings.items()) + f'}}; name = {level};')
for category in ('project','target'):
    add(category+'Config',f'isa = XCConfigurationList; buildConfigurations = ({uid(category+"Debug")},{uid(category+"Release")}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
add('target', f'isa = PBXNativeTarget; buildConfigurationList = {uid("targetConfig")}; buildPhases = ({uid("sources")},{uid("frameworks")},{uid("resources")}); buildRules = (); dependencies = (); name = VRecord; productName = VRecord; productReference = {uid("product")}; productType = "com.apple.product-type.application";')
add('project', f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 1640; }}; buildConfigurationList = {uid("projectConfig")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base); mainGroup = {uid("mainGroup")}; productRefGroup = {uid("productsGroup")}; projectDirPath = ""; projectRoot = ""; targets = ({uid("target")});')
project = root / 'VRecord.xcodeproj'
project.mkdir(exist_ok=True)
(project / 'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(objects) + f'\n}}; rootObject = {uid("project")}; }}\n')
schemes = project / 'xcshareddata/xcschemes'
schemes.mkdir(parents=True,exist_ok=True)
ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("target")}" BuildableName="VRecord.app" BlueprintName="VRecord" ReferencedContainer="container:VRecord.xcodeproj"/>'
(schemes / 'VRecord.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1640" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables/></TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(f'Generated Xcode project with {len(source)} Swift/Metal sources and app assets.')
