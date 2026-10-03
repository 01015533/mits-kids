import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('apk_check', Path(__file__).resolve().parents[1] / 'check_apk.py')
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.xml = '''<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.example.mits">
          <uses-sdk android:minSdkVersion="26" />
          <uses-permission android:name="android.permission.INTERNET" />
          <application android:debuggable="false" android:testOnly="false" android:allowBackup="false"
            android:usesCleartextTraffic="false" android:networkSecurityConfig="@xml/a"
            android:dataExtractionRules="@xml/b" android:fullBackupContent="@xml/c">
            <activity android:name="com.example.mits.MainActivity" android:exported="true"><intent-filter>
              <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter></activity>
          </application>
        </manifest>'''

    def test_launcher_is_permitted(self):
        check.check_manifest(self.xml)

    def test_omitted_debug_flag_has_android_safe_default(self):
        check.check_manifest(self.xml.replace('android:debuggable="false"', ''))

    def test_reviewed_media3_permissions_are_permitted(self):
        additions = ''.join(f'<uses-permission android:name="{permission}" />' for permission in (
            'android.permission.ACCESS_NETWORK_STATE', 'android.permission.WAKE_LOCK'))
        check.check_manifest(self.xml.replace('<uses-sdk', additions+'<uses-sdk'))

    def test_app_signature_permission_is_permitted_but_other_custom_permissions_are_not(self):
        name = 'com.example.mits.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION'
        additions = (f'<permission android:name="{name}" android:protectionLevel="signature" />'
                     f'<uses-permission android:name="{name}" />')
        check.check_manifest(self.xml.replace('<uses-sdk', additions+'<uses-sdk'))
        for changed in (additions.replace('signature', 'normal'), additions.replace(name, 'other.app.PERMISSION')):
            with self.subTest(changed=changed), self.assertRaisesRegex(ValueError, 'Unexpected permission'):
                check.check_manifest(self.xml.replace('<uses-sdk', changed+'<uses-sdk'))

    def test_unreviewed_android_permissions_remain_rejected(self):
        for permission in ('CAMERA', 'RECORD_AUDIO', 'READ_EXTERNAL_STORAGE', 'MANAGE_EXTERNAL_STORAGE',
                           'ACCESS_FINE_LOCATION', 'CHANGE_NETWORK_STATE', 'REQUEST_INSTALL_PACKAGES',
                           'BIND_DEVICE_ADMIN', 'FOREGROUND_SERVICE_LOCATION',
                           'FOREGROUND_SERVICE_MEDIA_PLAYBACK', 'RECEIVE_BOOT_COMPLETED'):
            addition = f'<uses-permission android:name="android.permission.{permission}" />'
            with self.subTest(permission=permission), self.assertRaisesRegex(ValueError, 'Unexpected permission'):
                check.check_manifest(self.xml.replace('<uses-sdk', addition+'<uses-sdk'))

    def approved_download_xml(self):
        permissions = ''.join(f'<uses-permission android:name="android.permission.{name}" />' for name in (
            'FOREGROUND_SERVICE', 'FOREGROUND_SERVICE_DATA_SYNC', 'POST_NOTIFICATIONS', 'WAKE_LOCK'))
        components = ('<service android:name="com.mitskids.offline.ApprovedDownloadService" '
            'android:exported="false" android:foregroundServiceType="dataSync" android:stopWithTask="false" />'
            '<receiver android:name="com.mitskids.offline.DownloadCancelReceiver" android:exported="false" />')
        return self.xml.replace('<uses-sdk', permissions+'<uses-sdk').replace('</application>', components+'</application>')

    def test_reviewed_private_download_service_and_cancel_receiver_are_permitted(self):
        xml = self.approved_download_xml()
        check.check_manifest(xml)
        for value in ('1', '0x1', '0x00000001'):
            check.check_manifest(xml.replace('foregroundServiceType="dataSync"', f'foregroundServiceType="{value}"'))

    def test_download_permissions_require_exact_private_components(self):
        xml = self.approved_download_xml()
        for changed in (
            xml.replace('com.mitskids.offline.ApprovedDownloadService', 'other.Service'),
            xml.replace('com.mitskids.offline.DownloadCancelReceiver', 'other.Receiver'),
            xml.replace('<uses-permission android:name="android.permission.WAKE_LOCK" />', ''),
            xml.replace('<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />', ''),
        ):
            with self.subTest(changed=changed), self.assertRaisesRegex(ValueError, 'declared together'):
                check.check_manifest(changed)
        for name in ('FOREGROUND_SERVICE', 'FOREGROUND_SERVICE_DATA_SYNC', 'POST_NOTIFICATIONS'):
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, 'declared together'):
                check.check_manifest(self.xml.replace('<uses-sdk',
                    f'<uses-permission android:name="android.permission.{name}" /><uses-sdk'))

    def test_unreviewed_foreground_types_and_download_exports_are_rejected(self):
        xml = self.approved_download_xml()
        for value in ('location', 'dataSync|mediaPlayback', '0x3'):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, 'Unexpected foreground'):
                check.check_manifest(xml.replace('foregroundServiceType="dataSync"', f'foregroundServiceType="{value}"'))
        for changed in (
            xml.replace('android:stopWithTask="false"', 'android:stopWithTask="true"'),
            xml.replace('ApprovedDownloadService" android:exported="false"', 'ApprovedDownloadService" android:exported="true"'),
            xml.replace('DownloadCancelReceiver" android:exported="false"', 'DownloadCancelReceiver" android:exported="true"'),
            xml.replace('DownloadCancelReceiver" android:exported="false" />',
                'DownloadCancelReceiver" android:exported="false"><intent-filter><action android:name="ANY" /></intent-filter></receiver>'),
        ):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                check.check_manifest(changed)

    def test_device_admin_is_rejected_even_when_not_exported(self):
        for receiver in (
            '<receiver android:name=".Admin" android:exported="false" android:permission="android.permission.BIND_DEVICE_ADMIN" />',
            '<receiver android:name=".Admin" android:exported="false"><meta-data android:name="android.app.device_admin" android:resource="@xml/admin" /></receiver>',
        ):
            with self.subTest(receiver=receiver), self.assertRaisesRegex(ValueError, 'Device administration'):
                check.check_manifest(self.xml.replace('</application>', receiver+'</application>'))

    def test_kiosk_and_home_launcher_configuration_is_rejected(self):
        for mode in ('always', 'if_whitelisted', '2', '3'):
            with self.subTest(mode=mode), self.assertRaisesRegex(ValueError, 'Kiosk'):
                check.check_manifest(self.xml.replace('<activity ', f'<activity android:lockTaskMode="{mode}" '))
        with self.assertRaisesRegex(ValueError, 'Kiosk'):
            check.check_manifest(self.xml.replace('</intent-filter>',
                '<category android:name="android.intent.category.HOME" /></intent-filter>'))
        check.check_manifest(self.xml.replace('<activity ', '<activity android:lockTaskMode="never" '))

    def test_shrunken_resource_paths_are_resolved_and_ambiguity_rejected(self):
        dump = '''  type xml id=0e entryCount=3
    resource 0x7f0e0000 xml/mits_backup_rules
      () (file) res/Sq.xml type=XML
    resource 0x7f0e0001 xml/mits_data_extraction_rules
      () (file) res/vA.xml type=XML
    resource 0x7f0e0002 xml/mits_network_security_config
      () (file) res/Pm.xml type=XML
'''
        result = check.policy_resources(dump)
        self.assertEqual(result['mits_network_security_config']['paths'], ['res/Pm.xml'])
        with self.assertRaisesRegex(ValueError, 'ambiguous'):
            check.policy_resources(dump+'      (v35) (file) res/other.xml type=XML\n')

    def test_debuggable_backup_cleartext_rejected(self):
        for name in ['debuggable', 'testOnly', 'allowBackup', 'usesCleartextTraffic']:
            with self.subTest(name=name), self.assertRaises(ValueError):
                check.check_manifest(self.xml.replace(f'android:{name}="false"', f'android:{name}="true"'))

    def test_unexpected_permissions_and_exports_rejected(self):
        for addition in ['<uses-permission android:name="android.permission.RECORD_AUDIO" />', '<uses-permission-sdk-23 android:name="android.permission.CAMERA" />']:
            with self.assertRaisesRegex(ValueError, 'Unexpected permission'):
                check.check_manifest(self.xml.replace('<uses-sdk', addition+'<uses-sdk'))
        with self.assertRaisesRegex(ValueError, 'Unexpected exported'):
            check.check_manifest(self.xml.replace('</application>', '<service android:name="x" android:exported="true" /></application>'))


if __name__ == '__main__':
    unittest.main()
