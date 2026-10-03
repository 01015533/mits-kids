#!/usr/bin/env python3
"""Inspect a locally built release APK without connecting to a device."""
import argparse
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

A = '{http://schemas.android.com/apk/res/android}'

# Media3 1.9.2 declares network observation and uses a local wake lock by
# default. Approved downloads add only the reviewed dataSync service and
# notification permissions. Other service types remain rejected.
ALLOWED_ANDROID_PERMISSIONS = {
    'android.permission.INTERNET',
    'android.permission.ACCESS_NETWORK_STATE',
    'android.permission.WAKE_LOCK',
    'android.permission.FOREGROUND_SERVICE',
    'android.permission.FOREGROUND_SERVICE_DATA_SYNC',
    'android.permission.POST_NOTIFICATIONS',
}

DOWNLOAD_SERVICE = 'com.mitskids.offline.ApprovedDownloadService'
DOWNLOAD_CANCEL_RECEIVER = 'com.mitskids.offline.DownloadCancelReceiver'
DOWNLOAD_PERMISSIONS = {
    'android.permission.FOREGROUND_SERVICE',
    'android.permission.FOREGROUND_SERVICE_DATA_SYNC',
    'android.permission.POST_NOTIFICATIONS',
}


def is_data_sync(value):
    if value in {'dataSync', '1'}:
        return True
    return bool(value and re.fullmatch(r'0[xX][0-9a-fA-F]+', value) and int(value, 16) == 1)


def check_manifest(xml):
    root = ET.fromstring(xml)
    app = root.find('application')
    if app is None:
        raise ValueError('Missing application element')
    # Android defaults debuggable to false. AGP owns this build-variant flag;
    # hardcoding it in source manifests triggers Android's fatal lint check.
    if app.get(A+'debuggable') not in {None, 'false'}:
        raise ValueError('Release must not enable android:debuggable')
    for name in ['testOnly', 'allowBackup', 'usesCleartextTraffic']:
        value = app.get(A + name)
        if value != 'false':
            raise ValueError(f'Release must explicitly set android:{name}=false (found {value!r})')
    for name in ['networkSecurityConfig', 'dataExtractionRules', 'fullBackupContent']:
        if not app.get(A + name):
            raise ValueError(f'Missing {name}')
    sdk = root.find('uses-sdk')
    if sdk is None or int(sdk.get(A + 'minSdkVersion', '0')) < 26:
        raise ValueError('Minimum Android API level must be at least 26')
    package = root.get('package', '')
    if root.find('instrumentation') is not None:
        raise ValueError('Release APK must not contain test instrumentation')
    defined = {p.get(A+'name') for p in root.findall('permission') if p.get(A+'protectionLevel') in {'signature', '0x2', '2'}}
    allowed = ALLOWED_ANDROID_PERMISSIONS | {name for name in defined if name and name.startswith(package+'.')}
    requested = [*root.findall('uses-permission'), *root.findall('uses-permission-sdk-23')]
    for permission in requested:
        if permission.get(A + 'name') not in allowed:
            raise ValueError(f'Unexpected permission: {permission.get(A + "name")}')
    requested_names = {permission.get(A+'name') for permission in requested}
    download_services = [node for node in app if node.get(A+'name') == DOWNLOAD_SERVICE]
    cancel_receivers = [node for node in app if node.get(A+'name') == DOWNLOAD_CANCEL_RECEIVER]
    if requested_names & DOWNLOAD_PERMISSIONS or download_services or cancel_receivers:
        if not (DOWNLOAD_PERMISSIONS | {'android.permission.WAKE_LOCK'}).issubset(requested_names) or \
                len(download_services) != 1 or len(cancel_receivers) != 1:
            raise ValueError('Approved download permissions and private components must be declared together')
    for component in app:
        if component.tag not in {'activity', 'activity-alias', 'service', 'receiver', 'provider'}:
            continue
        if component.get(A+'permission') == 'android.permission.BIND_DEVICE_ADMIN' or any(
                node.get(A+'name') == 'android.app.device_admin' for node in component.findall('meta-data')):
            raise ValueError('Device administration is outside the application scope')
        service_type = component.get(A+'foregroundServiceType')
        if service_type is not None and (component.tag != 'service' or
                component.get(A+'name') != DOWNLOAD_SERVICE or not is_data_sync(service_type)):
            raise ValueError('Unexpected foreground service type or component')
        if component.get(A+'name') == DOWNLOAD_SERVICE and (
                component.tag != 'service' or component.get(A+'exported') != 'false' or
                not is_data_sync(service_type) or
                component.get(A+'stopWithTask') != 'false' or component.findall('intent-filter')):
            raise ValueError('Approved download service policy is incomplete')
        if component.get(A+'name') == DOWNLOAD_CANCEL_RECEIVER and (
                component.tag != 'receiver' or component.get(A+'exported') != 'false' or
                component.findall('intent-filter')):
            raise ValueError('Download cancellation receiver must remain private and explicit')
        if component.get(A+'lockTaskMode') not in {None, 'never', '1'} or any(
                node.get(A+'name') == 'android.intent.category.HOME' for node in component.findall('./intent-filter/category')):
            raise ValueError('Kiosk or home-launcher integration is outside the application scope')
        if component.get(A+'exported') == 'true':
            is_launcher = component.tag == 'activity' and component.get(A+'name', '').endswith('.MainActivity') and any(
                node.get(A+'name') == 'android.intent.category.LAUNCHER' for node in component.findall('./intent-filter/category'))
            if not is_launcher:
                raise ValueError(f'Unexpected exported component: {component.get(A+"name")}')
        elif component.get(A+'exported') is None and component.findall('intent-filter'):
            raise ValueError(f'Component with intent filter lacks explicit exported policy: {component.get(A+"name")}')


def run(args):
    return subprocess.check_output([str(value) for value in args], text=True, stderr=subprocess.STDOUT, timeout=60)


def policy_resources(dump):
    """Follow AAPT's resource table: release shrinking renames XML files."""
    entries = {}
    current = None
    for line in dump.splitlines():
        match = re.search(r'resource\s+(0x[0-9a-fA-F]+)\s+xml/(mits_\w+)', line)
        if match:
            number, name = match.groups()
            entries[name] = {'id': number.lower(), 'paths': []}
            current = name
        elif re.search(r'^\s*(?:resource|type)\s', line):
            current = None
        elif current:
            file = re.search(r'\(file\)\s+(\S+)\s+type=XML', line)
            if file:
                entries[current]['paths'].append(file.group(1))
    for name in ['mits_network_security_config', 'mits_backup_rules', 'mits_data_extraction_rules']:
        if name not in entries or len(entries[name]['paths']) != 1:
            raise ValueError(f'Missing or ambiguous compiled policy: {name}')
    return entries


def verify(apk, sdk):
    analyzers = sorted((sdk/'cmdline-tools').glob('*/bin/apkanalyzer'))
    signers = sorted((sdk/'build-tools').glob('*/apksigner'))
    if not analyzers or not signers:
        raise ValueError('Install Android SDK command-line tools and build-tools first.')
    analyzer = analyzers[-1]
    manifest_xml = run([analyzer, 'manifest', 'print', apk])
    check_manifest(manifest_xml)
    application = ET.fromstring(manifest_xml).find('application')
    aapt = signers[-1].with_name('aapt2')
    resources = run([aapt, 'dump', 'resources', apk])
    policies = policy_resources(resources)
    for attribute, name in [('networkSecurityConfig', 'mits_network_security_config'), ('fullBackupContent', 'mits_backup_rules'), ('dataExtractionRules', 'mits_data_extraction_rules')]:
        value = application.get(A+attribute, '')
        resource_id = policies[name]['id']
        if value != '@xml/'+name and not (resource_id and re.search(r'0x[0-9a-fA-F]+', value) and re.search(r'0x[0-9a-fA-F]+', value).group().lower() == resource_id):
            raise ValueError(f'Manifest {attribute} does not reference the reviewed resource')
    for name in ['mits_network_security_config', 'mits_backup_rules', 'mits_data_extraction_rules']:
        xml = run([analyzer, 'resources', 'xml', '--file', policies[name]['paths'][0], apk])
        root = ET.fromstring(xml)
        if name == 'mits_network_security_config':
            base = root.find('base-config')
            if base is None or base.get('cleartextTrafficPermitted') != 'false':
                raise ValueError('Cleartext networking is not disabled')
            if root.find('debug-overrides') is not None or any(n.get('src') != 'system' for n in root.iter('certificates')):
                raise ValueError('Unexpected TLS trust overrides')
            if root.find('domain-config') is not None:
                raise ValueError('Unexpected domain-specific network overrides')
        else:
            scopes = [root] if name == 'mits_backup_rules' else [root.find('cloud-backup'), root.find('device-transfer')]
            required = {'root', 'file', 'database', 'sharedpref', 'external', 'device_root', 'device_file', 'device_database', 'device_sharedpref'}
            for scope in scopes:
                if scope is None or {e.get('domain') for e in scope.findall('exclude') if e.get('path') == '.'} != required:
                    raise ValueError('Backup or transfer exclusions are incomplete')
                if scope.find('include') is not None:
                    raise ValueError('Unexpected backup inclusion')
    signing = run([signers[-1], 'verify', '--verbose', '--print-certs', apk])
    if re.search(r'CN\s*=\s*Android Debug', signing, re.I):
        raise ValueError('APK is signed with an Android debug certificate')
    fingerprints = [line for line in signing.splitlines() if 'certificate SHA-256 digest:' in line]
    if not fingerprints:
        raise ValueError('APK signing certificate was not reported')
    print('Release APK checks passed: manifest, permission scope, exports, TLS policy, backup exclusions and signature.')
    print('\n'.join(fingerprints))
    print('Compare the signing fingerprint with your own key. Runtime checks on an Android device remain separate.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk', type=Path)
    parser.add_argument('--sdk', type=Path, required=True)
    args = parser.parse_args()
    try:
        verify(args.apk.resolve(), args.sdk.resolve())
    except subprocess.CalledProcessError as error:
        parser.exit(1, f'APK check failed: {error.output or error}\n')
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f'APK check failed: {error}\n')
