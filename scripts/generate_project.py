#!/usr/bin/env python3
"""Generate the checked-in Xcode project using only Python's standard library."""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
ECG_INTERACTION = '--ecg-interaction' in sys.argv
PHONE_ONLY = '--phone-only' in sys.argv or ECG_INTERACTION
PROJECT_NAME = 'QingkongECGPreview' if ECG_INTERACTION else 'QingkongPhonePreview' if PHONE_ONLY else 'Qingkong'
project_file = ROOT / f'{PROJECT_NAME}.xcodeproj/project.pbxproj'
UPDATE_EXISTING = project_file.exists() and '--recreate-project' not in sys.argv
existing_text = project_file.read_text() if UPDATE_EXISTING and project_file.exists() else None
existing = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(project_file)])) if existing_text else None
version_settings = next((o['buildSettings'] for o in (existing or {}).get('objects', {}).values()
                         if o.get('isa') == 'XCBuildConfiguration' and o.get('buildSettings', {}).get('PRODUCT_BUNDLE_IDENTIFIER') == 'cn.geckoai.qingkong'), {})
objects = {}

def uid(key):
    return hashlib.sha1(key.encode()).hexdigest()[:24].upper()

class Ref(str):
    pass

def add(key, isa, **values):
    identifier = uid(key)
    objects[identifier] = dict(isa=isa, **values)
    return Ref(identifier)

def encode(value, level=0):
    if isinstance(value, Ref):
        return str(value)
    if isinstance(value, dict):
        return '{\n' + ''.join('\t' * (level+1) + f'{json.dumps(str(k))} = {encode(v, level+1)};\n' for k,v in value.items()) + '\t' * level + '}'
    if isinstance(value, list):
        return '(' + ', '.join(encode(v, level) for v in value) + ')'
    if isinstance(value, int):
        return str(value)
    return json.dumps(str(value), ensure_ascii=False)

def configs(key, base, kind='target'):
    values=[]
    for name in ('Debug','Release'):
        settings=dict(base)
        settings.update(SWIFT_OPTIMIZATION_LEVEL='-Onone' if name=='Debug' else '-O', DEBUG_INFORMATION_FORMAT='dwarf' if name=='Debug' else 'dwarf-with-dsym')
        if name=='Debug':
            settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='DEBUG $(inherited)'
            settings['ONLY_ACTIVE_ARCH']='YES'
        values.append(add(f'{key}.{name}', 'XCBuildConfiguration', name=name, buildSettings=settings))
    return add(f'{key}.configList','XCConfigurationList',buildConfigurations=values,defaultConfigurationIsVisible=0,defaultConfigurationName='Release')

project_id=Ref(uid('project'))
files={}
def file(path, kind=None):
    if path in files: return files[path]
    ext=Path(path).suffix
    kind=kind or {'.swift':'sourcecode.swift','.xcassets':'folder.assetcatalog','.plist':'text.plist.xml','.entitlements':'text.plist.entitlements','.xcprivacy':'text.xml','.wav':'audio.wav','.jpg':'image.jpeg','.png':'image.png'}.get(ext,'text')
    files[path]=add('file.'+path,'PBXFileReference',lastKnownFileType=kind,path=path,sourceTree='SOURCE_ROOT')
    return files[path]

common=[p.relative_to(ROOT).as_posix() for p in sorted((ROOT/'Sources/Shared').glob('*.swift'))]
resources=['Resources/Assets.xcassets','Resources/PrivacyInfo.xcprivacy']
resources += [p.relative_to(ROOT).as_posix() for folder in ['Audio','Wallpapers'] for p in sorted((ROOT/'Resources'/folder).glob('*')) if p.is_file()]
package=add('package','XCLocalSwiftPackageReference',relativePath='Packages/QingkongCore')
products=[]
targets={}
specs=[
    ('Qingkong','iOS','iphoneos','iphoneos iphonesimulator','1','cn.geckoai.qingkong','com.apple.product-type.application',resources+['Resources/iOS/Assets.xcassets']),
    ('QingkongWatch','Watch','watchos','watchos watchsimulator','4','cn.geckoai.qingkong.watchapp','com.apple.product-type.application',resources+['Resources/Watch/Assets.xcassets']),
    ('QingkongWidgets','Widgets','watchos','watchos watchsimulator','4','cn.geckoai.qingkong.watchapp.widgets','com.apple.product-type.app-extension',['Resources/PrivacyInfo.xcprivacy','Resources/Assets.xcassets']),
    ('QingkongPhoneWidgets','iOSWidgets','iphoneos','iphoneos iphonesimulator','1','cn.geckoai.qingkong.widgets','com.apple.product-type.app-extension',['Resources/PrivacyInfo.xcprivacy','Resources/Assets.xcassets']),
    ('QingkongUITests','Tests','iphoneos','iphoneos iphonesimulator','1','cn.geckoai.qingkong.uitests','com.apple.product-type.bundle.ui-testing',[]),
    ('QingkongTests','UnitTests','iphoneos','iphoneos iphonesimulator','1','cn.geckoai.qingkong.tests','com.apple.product-type.bundle.unit-test',[])
]
for name,folder,sdk,platforms,family,bundle,product_type,assets in specs:
    is_test = folder in ('Tests', 'UnitTests')
    suffix='.appex' if folder in ('Widgets', 'iOSWidgets') else '.xctest' if is_test else '.app'
    product=add(name+'.product','PBXFileReference',explicitFileType='wrapper.app-extension' if suffix=='.appex' else 'wrapper.cfbundle' if suffix=='.xctest' else 'wrapper.application',includeInIndex=0,path=name+suffix,sourceTree='BUILT_PRODUCTS_DIR')
    products.append(product)
    if is_test:
        sources=[p.relative_to(ROOT).as_posix() for p in sorted((ROOT/f'Tests/{name}').glob('*.swift'))]
    elif folder=='Widgets':
        sources=['Sources/Shared/SnapshotStorage.swift','Sources/Shared/Appearance.swift']+[p.relative_to(ROOT).as_posix() for p in sorted((ROOT/'Sources/Widgets').glob('*.swift'))]+[p.relative_to(ROOT).as_posix() for p in sorted((ROOT/'Sources/WidgetShared').glob('*.swift'))]
    elif folder=='iOSWidgets':
        sources=['Sources/Shared/SnapshotStorage.swift','Sources/Shared/WidgetAudioStorage.swift']+[p.relative_to(ROOT).as_posix() for p in sorted((ROOT/'Sources/iOSWidgets').glob('*.swift'))]+[p.relative_to(ROOT).as_posix() for p in sorted((ROOT/'Sources/WidgetShared').glob('*.swift'))]
    else:
        sources=common+[p.relative_to(ROOT).as_posix() for p in sorted((ROOT/f'Sources/{folder}').glob('*.swift'))]
        if folder == 'iOS':
            sources += ['Sources/Watch/DumplingArtwork.swift','Sources/WidgetShared/MusicPlaybackIntent.swift']
    if ECG_INTERACTION and folder == 'iOS':
        sources = [s for s in sources if s != 'Sources/iOS/QingkongApp.swift'] + ['Tests/InteractionFixtures/ECGFixtureApp.swift']
    if ECG_INTERACTION and folder == 'Tests':
        sources = ['Tests/InteractionFixtures/ECGScrollingUITests.swift']
    source_phase=add(name+'.sources','PBXSourcesBuildPhase',buildActionMask=2147483647,files=[add(name+'.build.'+s,'PBXBuildFile',fileRef=file(s)) for s in sources],runOnlyForDeploymentPostprocessing=0)
    resource_phase=add(name+'.resources','PBXResourcesBuildPhase',buildActionMask=2147483647,files=[add(name+'.build.'+s,'PBXBuildFile',fileRef=file(s)) for s in assets],runOnlyForDeploymentPostprocessing=0)
    dependencies=[]
    frameworks=[]
    if folder!='Tests':
        dep=add(name+'.package','XCSwiftPackageProductDependency',package=package,productName='QingkongCore')
        dependencies=[dep]
        frameworks=[add(name+'.core','PBXBuildFile',productRef=dep)]
    framework_phase=add(name+'.frameworks','PBXFrameworksBuildPhase',buildActionMask=2147483647,files=frameworks,runOnlyForDeploymentPostprocessing=0)
    settings=dict(PRODUCT_NAME='$(TARGET_NAME)',PRODUCT_BUNDLE_IDENTIFIER=bundle,SDKROOT=sdk,SUPPORTED_PLATFORMS=platforms,TARGETED_DEVICE_FAMILY=family,SWIFT_VERSION='5.0',SWIFT_STRICT_CONCURRENCY='targeted',IPHONEOS_DEPLOYMENT_TARGET='18.0',WATCHOS_DEPLOYMENT_TARGET='11.0',CODE_SIGN_STYLE='Automatic',MARKETING_VERSION='0.1.0',CURRENT_PROJECT_VERSION='4' if is_test else '13',LD_RUNPATH_SEARCH_PATHS=['$(inherited)','@executable_path/Frameworks'],ENABLE_USER_SCRIPT_SANDBOXING='YES',GENERATE_INFOPLIST_FILE='NO',SWIFT_EMIT_LOC_STRINGS='YES',LOCALIZATION_PREFERS_STRING_CATALOGS='YES',CLANG_ENABLE_MODULES='YES',SWIFT_SERIALIZE_DEBUGGING_OPTIONS='NO')
    if not is_test:
        settings.update(INFOPLIST_FILE=f'Config/{folder}-Info.plist',CODE_SIGN_ENTITLEMENTS=f'Config/{folder}.entitlements')
        settings['INFOPLIST_KEY_CFBundleDisplayName']='小晴空'
    if folder == 'iOS': settings['INFOPLIST_KEY_LSApplicationCategoryType']='public.app-category.utilities'
    settings['DEVELOPMENT_TEAM']='9S743LF4C7'
    for setting in ('CURRENT_PROJECT_VERSION', 'MARKETING_VERSION'):
        if not is_test and setting in version_settings: settings[setting] = version_settings[setting]
    if folder in ('iOS','Watch'):
        settings['ASSETCATALOG_COMPILER_APPICON_NAME']='AppIcon'
    if folder=='Watch': settings.update(SKIP_INSTALL='YES',WK_APPLICATION='YES')
    if folder in ('Widgets', 'iOSWidgets'):
        settings.update(SKIP_INSTALL='YES',APPLICATION_EXTENSION_API_ONLY='YES',LD_RUNPATH_SEARCH_PATHS=['$(inherited)','@executable_path/Frameworks','@executable_path/../../Frameworks'])
    if folder=='Tests': settings.update(GENERATE_INFOPLIST_FILE='YES',TEST_TARGET_NAME='Qingkong',SKIP_INSTALL='YES')
    if folder=='UnitTests': settings.update(GENERATE_INFOPLIST_FILE='YES',TEST_HOST='$(BUILT_PRODUCTS_DIR)/Qingkong.app/Qingkong',BUNDLE_LOADER='$(TEST_HOST)',SKIP_INSTALL='YES')
    target=add(name,'PBXNativeTarget',name=name,productName=name,productReference=product,productType=product_type,buildConfigurationList=configs(name,settings),buildPhases=[source_phase,framework_phase,resource_phase],buildRules=[],dependencies=[],packageProductDependencies=dependencies)
    targets[name]=target

def dependency(parent, child):
    proxy=add(parent+'.proxy.'+child,'PBXContainerItemProxy',containerPortal=project_id,proxyType=1,remoteGlobalIDString=targets[child],remoteInfo=child)
    dep=add(parent+'.dependency.'+child,'PBXTargetDependency',target=targets[child],targetProxy=proxy)
    objects[targets[parent]]['dependencies'].append(dep)

def embed(parent, child, dst, path):
    dependency(parent,child)
    build=add(parent+'.embed.'+child,'PBXBuildFile',fileRef=objects[targets[child]]['productReference'],settings={'ATTRIBUTES':['RemoveHeadersOnCopy']})
    phase=add(parent+'.embedPhase.'+child,'PBXCopyFilesBuildPhase',buildActionMask=2147483647,dstPath=path,dstSubfolderSpec=dst,files=[build],name='Embed '+child,runOnlyForDeploymentPostprocessing=0)
    objects[targets[parent]]['buildPhases'].append(phase)

if not PHONE_ONLY:
    embed('Qingkong','QingkongWatch',16,'$(CONTENTS_FOLDER_PATH)/Watch')
embed('QingkongWatch','QingkongWidgets',13,'')
embed('Qingkong','QingkongPhoneWidgets',13,'')
dependency('QingkongUITests','Qingkong')
dependency('QingkongTests','Qingkong')
for p in sorted((ROOT/'Config').iterdir()): file(p.relative_to(ROOT).as_posix())
source_group=add('sourcesGroup','PBXGroup',name='Sources and Resources',children=list(files.values()),sourceTree='<group>')
product_group=add('productsGroup','PBXGroup',name='Products',children=products,sourceTree='<group>')
main_group=add('mainGroup','PBXGroup',children=[source_group,product_group],sourceTree='<group>')
project_config=configs('project',dict(CLANG_ENABLE_OBJC_ARC='YES',CLANG_WARN_DOCUMENTATION_COMMENTS='YES',GCC_C_LANGUAGE_STANDARD='gnu17',SWIFT_VERSION='5.0',ENABLE_TESTABILITY='YES',ALWAYS_SEARCH_USER_PATHS='NO',COPY_PHASE_STRIP='NO',DEAD_CODE_STRIPPING='YES'))
add('project','PBXProject',attributes={'BuildIndependentTargetsInParallel':'YES','LastUpgradeCheck':'2660','TargetAttributes':{str(targets['QingkongUITests']):{'TestTargetID':targets['Qingkong']}}},buildConfigurationList=project_config,compatibilityVersion='Xcode 14.0',developmentRegion='zh_CN',hasScannedForEncodings=0,knownRegions=['zh_CN','en','Base'],mainGroup=main_group,productRefGroup=product_group,projectDirPath='',projectRoot='',targets=list(targets.values()),packageReferences=[package])
project=ROOT/f'{PROJECT_NAME}.xcodeproj'
project.mkdir(exist_ok=True)
if existing:
    # Add only new references and phases. Preserve Xcode-managed signing, versions,
    # settings, file ordering, and schemes instead of rebuilding the user's project.
    text = existing_text
    additions = {}
    for identifier, generated in objects.items():
        old = existing['objects'].get(identifier)
        if old is None:
            additions.setdefault(generated['isa'], []).append((identifier, generated))
            continue
        changed = False
        for key in ('children', 'targets', 'buildPhases', 'dependencies', 'files', 'packageProductDependencies'):
            if key not in generated: continue
            for value in generated[key]:
                if value not in old.setdefault(key, []):
                    old[key].append(value)
                    changed = True
        if changed:
            pattern = re.compile(r'^\t\t"?' + identifier + r'"?(?: /\*.*?\*/)? = \{.*?^\t\t\};', re.M | re.S)
            text, count = pattern.subn(lambda _: '\t\t' + identifier + ' = ' + encode(old, 2) + ';', text)
            if count != 1: raise RuntimeError('Cannot safely update project object ' + identifier)
    for isa, entries in additions.items():
        chunk = ''.join('\t\t' + identifier + ' = ' + encode(value, 2) + ';\n' for identifier, value in entries)
        marker = '/* End ' + isa + ' section */'
        if marker in text:
            text = text.replace(marker, chunk + marker, 1)
        else:
            # Projects emitted by this generator have no Xcode section comments.
            boundary = '\n\t};\n\t"rootObject"'
            if boundary not in text: raise RuntimeError('Cannot locate project objects boundary')
            text = text.replace(boundary, '\n' + chunk + boundary, 1)
else:
    text='// !$*UTF8*$!\n'+encode({'archiveVersion':1,'classes':{},'objectVersion':60,'objects':{Ref(k):v for k,v in objects.items()},'rootObject':project_id})+'\n'
(project/'project.pbxproj').write_text(text)
schemes=project/'xcshareddata/xcschemes'; schemes.mkdir(parents=True,exist_ok=True)
for name in ['Qingkong','QingkongWatch']:
    if UPDATE_EXISTING and (schemes/f'{name}.xcscheme').exists(): continue
    ref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{targets[name]}" BuildableName="{name}.app" BlueprintName="{name}" ReferencedContainer="container:{PROJECT_NAME}.xcodeproj"/>'
    testref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{targets["QingkongUITests"]}" BuildableName="QingkongUITests.xctest" BlueprintName="QingkongUITests" ReferencedContainer="container:{PROJECT_NAME}.xcodeproj"/>'
    unitref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{targets["QingkongTests"]}" BuildableName="QingkongTests.xctest" BlueprintName="QingkongTests" ReferencedContainer="container:{PROJECT_NAME}.xcodeproj"/>'
    testables=f'<TestableReference skipped="NO">{unitref}</TestableReference><TestableReference skipped="NO">{testref}</TestableReference>' if name=='Qingkong' else ''
    if ECG_INTERACTION and name == 'Qingkong':
        testables = f'<TestableReference skipped="NO">{testref}</TestableReference>'
    (schemes/f'{name}.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2660" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables>{testables}</Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(f'Generated {PROJECT_NAME}.xcodeproj ({len(specs)} targets, 2 shared schemes, local QingkongCore package).')
