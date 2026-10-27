import copy
import json
from pathlib import Path
import tempfile
import unittest

from tools import store_assets


def sample_copy():
    return {'version': '1.0.13', 'localizations': {
        'zh-Hans': {'description': '前后双摄，同框记录。', 'whatsNew': '优化大屏布局。'},
        'zh-Hant': {'description': '前後雙鏡頭，同框記錄。', 'whatsNew': '改善大螢幕版面。'},
        'en-US': {'description': 'Record both perspectives.', 'whatsNew': 'Improved larger-screen layouts.'}}}


class MetadataBoundary:
    def __init__(self, state='PREPARE_FOR_SUBMISSION', mismatch=False):
        self.state, self.mismatch = state, mismatch
        self.locales = {code: {'id': 'id-' + code, 'attributes': {
            'locale': code, 'description': 'old description', 'whatsNew': 'old notes',
            'keywords': 'keep keyword', 'supportUrl': 'https://example.com/keep'}}
            for code in ('zh-Hans', 'zh-Hant', 'en-US')}

    def api(self, method, path, body=None, params=None):
        if method == 'GET' and path == '/v1/appStoreVersions/version-id':
            return {'data': {'id': 'version-id', 'attributes': {
                'versionString': '1.0.13', 'platform': 'IOS', 'appStoreState': self.state}}}
        if method == 'GET' and path.endswith('/appStoreVersionLocalizations'):
            return {'data': copy.deepcopy(list(self.locales.values()))}
        for locale in self.locales.values():
            if path == '/v1/appStoreVersionLocalizations/' + locale['id']:
                if method == 'PATCH':
                    if body['data']['id'] != locale['id']:
                        raise AssertionError('错误本地化 ID')
                    locale['attributes'].update(body['data']['attributes'])
                result = copy.deepcopy(locale)
                if method == 'GET' and self.mismatch:
                    result['attributes']['description'] = 'unexpected server text'
                return {'data': result}
        raise AssertionError((method, path))


class StoreCopyTests(unittest.TestCase):
    def run_update(self, client, content=None):
        report = {'versions': [{'id': 'version-id', 'attributes': {
            'versionString': '1.0.13', 'platform': 'IOS'}}]}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'copy.json'
            path.write_text(json.dumps(content or sample_copy(), ensure_ascii=False), encoding='utf-8')
            store_assets.update_metadata(client, report, path, lambda: None)
        return report

    def test_updates_both_fields_in_all_three_locales_without_touching_other_metadata(self):
        client = MetadataBoundary()
        result = self.run_update(client)
        for code, desired in sample_copy()['localizations'].items():
            actual = client.locales[code]['attributes']
            self.assertEqual(actual['description'], desired['description'])
            self.assertEqual(actual['whatsNew'], desired['whatsNew'])
            self.assertEqual(actual['keywords'], 'keep keyword')
            self.assertEqual(actual['supportUrl'], 'https://example.com/keep')
        self.assertEqual(set(result['metadataVerified']), {'zh-Hans', 'zh-Hant', 'en-US'})
        self.assertTrue(result['metadataComplete'])

    def test_published_version_is_never_changed(self):
        client = MetadataBoundary(state='READY_FOR_SALE')
        with self.assertRaises(ValueError):
            self.run_update(client)
        self.assertEqual(client.locales['zh-Hans']['attributes']['description'], 'old description')

    def test_locale_inventory_mismatch_stops_before_any_write(self):
        client = MetadataBoundary()
        del client.locales['zh-Hant']
        with self.assertRaises(ValueError):
            self.run_update(client)
        self.assertEqual(client.locales['zh-Hans']['attributes']['description'], 'old description')

    def test_read_back_mismatch_is_not_reported_as_success(self):
        with self.assertRaises(ValueError):
            self.run_update(MetadataBoundary(mismatch=True))

    def test_empty_oversized_and_extra_fields_are_rejected_before_write(self):
        for change in [lambda c: c['localizations']['en-US'].update(whatsNew=''),
                       lambda c: c['localizations']['en-US'].update(description='x' * 4001),
                       lambda c: c['localizations']['zh-Hans'].update(keywords='do not change')]:
            client = MetadataBoundary()
            payload = sample_copy()
            change(payload)
            with self.assertRaises(ValueError):
                self.run_update(client, payload)
            self.assertEqual(client.locales['zh-Hans']['attributes']['description'], 'old description')


if __name__ == '__main__':
    unittest.main()
