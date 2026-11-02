import copy
from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

from tools import store_assets


LOCALES = ('zh-Hans', 'zh-Hant', 'en-US')
SIZES = {'iphone': [10, 20], 'ipad': [20, 30], 'duo': [30, 40]}


def manifest_fixture(root):
    items = []
    for locale in LOCALES:
        for device, size in SIZES.items():
            for order in range(1, 7):
                key = f'{locale}-{device}-{order:02d}'
                header = (b'\x89PNG\r\n\x1a\n' + struct.pack('>I', 13) + b'IHDR'
                          + struct.pack('>IIBBBBB', *size, 8, 2, 0, 0, 0))
                (root / f'{key}.png').write_bytes(header)
                items.append({'key': key, 'file': f'{key}.png', 'size': size,
                              'category': 'APP_SCREENSHOTS_AND_PREVIEWS',
                              'referenceName': key, 'locale': locale,
                              'device': device, 'order': order})
    return items


def report_fixture():
    return {'app': {'id': 'app', 'attributes': {'primaryLocale': 'zh-Hans'}},
            'library': {'id': 'library'},
            'versions': [{'id': 'version', 'attributes': {
                'versionString': '1.0.13', 'platform': 'IOS'}}],
            'referenceData': [{'attributes': {
                'imageSpecs': [{'specId': device, 'dimensions': {
                    'minWidth': size[0], 'maxWidth': size[0],
                    'minHeight': size[1], 'maxHeight': size[1]}}
                    for device, size in SIZES.items()],
                'placementTypes': [{'placementTypeId': 'APP_SCREENSHOT',
                    'specMappings': [{'placementGroupId': device.upper(), 'specs': [device]}
                                     for device in SIZES]}]}}]}


class AppleBoundary:
    """只模拟外部 API；真实上传规划、素材复用和顺序验证全部运行。"""

    def __init__(self):
        self.writes = []
        self.images = {}
        self.placements = {}
        self.locales = [{'id': f'fresh-{locale}', 'attributes': {'locale': locale}}
                        for locale in LOCALES]
        for locale in LOCALES:
            self.placements[f'fresh-{locale}'] = [
                self.placement(f'header-{locale}', 'PRODUCT_PAGE_HEADER_ASSET', 'HEADER', 'old-header'),
                self.placement(f'search-{locale}', 'APP_STORE_SEARCH_RESULTS_ASSET', 'SEARCH', 'old-search'),
                self.placement(f'legacy-{locale}', 'APP_SCREENSHOT', 'IPHONE', 'old-screen')]

    @staticmethod
    def placement(identifier, kind, group, image):
        return {'id': identifier, 'attributes': {'placementType': kind, 'placementGroup': group,
                    'state': 'PARENT_PREPARE_FOR_SUBMISSION'},
                'relationships': {'image': {'data': {'type': 'appAssetLibraryImages', 'id': image}}}}

    def api(self, method, path, body=None, params=None):
        if method != 'GET':
            self.writes.append((method, path, copy.deepcopy(body)))
        if path == '/v1/appStoreVersions/version':
            return {'data': {'id': 'version', 'attributes': {'versionString': '1.0.13',
                            'platform': 'IOS', 'appStoreState': 'PREPARE_FOR_SUBMISSION'}}}
        if path.endswith('/appStoreVersionLocalizations'):
            return {'data': copy.deepcopy(self.locales)}
        if path.endswith('/images?limit=200'):
            return {'data': list(self.images.values())}
        if method == 'POST' and path == '/v1/appAssetLibraryImages':
            asset = {'id': body['data']['attributes']['fileName'].removesuffix('.png'),
                     'attributes': {**body['data']['attributes'], 'state': 'PREPARE_FOR_SUBMISSION'}}
            self.images[asset['id']] = asset
            return {'data': copy.deepcopy(asset)}
        if path.startswith('/v1/appAssetLibraryImages/'):
            return {'data': copy.deepcopy(self.images[path.rsplit('/', 1)[-1]])}
        if method == 'GET' and path.endswith('/placements'):
            locale_id = path.split('/')[-2]
            rows = self.placements[locale_id]
            if params:
                rows = [row for row in rows if all(row['attributes'][field] == params[f'filter[{field}]']
                    for field in ('placementType', 'placementGroup') if f'filter[{field}]' in params)]
            return {'data': copy.deepcopy(rows)}
        if method == 'DELETE' and path.startswith('/v1/appAssetLibraryPlacements/'):
            identifier = path.rsplit('/', 1)[-1]
            for rows in self.placements.values():
                rows[:] = [row for row in rows if row['id'] != identifier]
            return {}
        if method == 'POST' and path == '/v1/appAssetLibraryPlacements':
            data = body['data']
            image = data['relationships']['image']['data']['id']
            locale = data['relationships']['appStoreVersionLocalization']['data']['id']
            row = self.placement(f'p-{image}', data['attributes']['placementType'],
                                 data['attributes']['placementGroup'], image)
            self.placements[locale].append(row)
            return {'data': copy.deepcopy(row)}
        if path == '/v1/appAssetLibraryPlacementOrderingRequests':
            data = body['data']
            locale = data['relationships']['appStoreVersionLocalization']['data']['id']
            order = [row['id'] for row in data['relationships']['orderedPlacements']['data']]
            self.placements[locale].sort(key=lambda row: order.index(row['id']) if row['id'] in order else -1)
            return {'data': {'id': 'ordering'}}
        raise AssertionError((method, path, params))


class LocalizedStoreAssetTests(unittest.TestCase):
    def setUp(self):
        self.enterContext(redirect_stdout(io.StringIO()))

    def test_new_version_gets_all_54_screenshots_without_touching_published_version(self):
        class NewVersionBoundary(AppleBoundary):
            def __init__(self):
                super().__init__()
                self.new_version = {'id': 'new-version', 'attributes': {
                    'versionString': '1.0.14', 'platform': 'IOS',
                    'appStoreState': 'PREPARE_FOR_SUBMISSION'}}
                self.published_accesses = []

            def api(self, method, path, body=None, params=None):
                if path.startswith('/v1/appStoreVersions/version'):
                    self.published_accesses.append((method, path))
                    raise AssertionError('不得对已发布 1.0.13 版本操作')
                if method == 'POST' and path == '/v1/appStoreVersions':
                    self.writes.append((method, path, copy.deepcopy(body)))
                    if body['data']['attributes']['versionString'] != '1.0.14':
                        raise AssertionError('创建了错误版本')
                    return {'data': copy.deepcopy(self.new_version)}
                if path == '/v1/appStoreVersions/new-version':
                    return {'data': copy.deepcopy(self.new_version)}
                return super().api(method, path, body, params)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / 'manifest.json'
            path.write_text(json.dumps(manifest_fixture(root)))
            for existing_draft in (False, True):
                with self.subTest(existing_draft=existing_draft):
                    boundary = NewVersionBoundary()
                    report = report_fixture()
                    report['requestedVersion'] = '1.0.14'
                    report['versions'][0]['attributes']['appStoreState'] = 'READY_FOR_DISTRIBUTION'
                    if existing_draft:
                        report['versions'].append(copy.deepcopy(boundary.new_version))
                    store_assets.upload(boundary, report, path, True, lambda: None)
                    self.assertEqual(report['targetVersion']['id'], 'new-version')
                    self.assertEqual(report['targetVersion']['version'], '1.0.14')
                    self.assertEqual(len(report['placements']), 54)
                    self.assertEqual(boundary.published_accesses, [])
                    self.assertTrue(report['complete'])

    def test_metadata_version_must_match_requested_target(self):
        class MetadataBoundary(AppleBoundary):
            def api(self, method, path, body=None, params=None):
                if path == '/v1/appStoreVersions/new-version':
                    return {'data': {'id': 'new-version', 'attributes': {
                        'versionString': '1.0.14', 'platform': 'IOS',
                        'appStoreState': 'PREPARE_FOR_SUBMISSION'}}}
                for row in self.locales:
                    if path == '/v1/appStoreVersionLocalizations/' + row['id']:
                        if method == 'PATCH':
                            self.writes.append((method, path, copy.deepcopy(body)))
                            row['attributes'].update(body['data']['attributes'])
                        return {'data': copy.deepcopy(row)}
                return super().api(method, path, body, params)
        report = {'requestedVersion': '1.0.14', 'versions': [
            {'id': 'old-version', 'attributes': {'versionString': '1.0.13', 'platform': 'IOS'}},
            {'id': 'new-version', 'attributes': {'versionString': '1.0.14', 'platform': 'IOS'}}]}
        content = {'version': '1.0.14', 'localizations': {locale: {
            'description': f'{locale} description', 'whatsNew': f'{locale} notes'} for locale in LOCALES}}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'copy.json'
            boundary = MetadataBoundary()
            content['version'] = '1.0.13'
            path.write_text(json.dumps(content))
            with self.assertRaises(ValueError):
                store_assets.update_metadata(boundary, report, path, lambda: None)
            self.assertEqual(boundary.writes, [])
            content['version'] = '1.0.14'
            path.write_text(json.dumps(content))
            store_assets.update_metadata(boundary, report, path, lambda: None)
        self.assertEqual(report['metadataVersion'], {'id': 'new-version', 'version': '1.0.14'})
        self.assertTrue(report['metadataComplete'])
        self.assertEqual(len(boundary.writes), 3)

    def test_new_draft_recheck_rejects_wrong_version_or_published_state_before_writes(self):
        class RecheckBoundary(AppleBoundary):
            def __init__(self, version_string, state):
                super().__init__()
                self.version_string, self.state = version_string, state

            def api(self, method, path, body=None, params=None):
                if path == '/v1/appStoreVersions/new-version':
                    return {'data': {'id': 'new-version', 'attributes': {
                        'versionString': self.version_string, 'platform': 'IOS',
                        'appStoreState': self.state}}}
                return super().api(method, path, body, params)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / 'manifest.json'
            path.write_text(json.dumps(manifest_fixture(root)))
            for version_string, state in [('1.0.13', 'PREPARE_FOR_SUBMISSION'),
                                           ('1.0.14', 'READY_FOR_DISTRIBUTION')]:
                with self.subTest(version_string=version_string, state=state):
                    report = report_fixture()
                    report['requestedVersion'] = '1.0.14'
                    report['versions'].append({'id': 'new-version', 'attributes': {
                        'versionString': '1.0.14', 'platform': 'IOS'}})
                    boundary = RecheckBoundary(version_string, state)
                    with self.assertRaises(ValueError):
                        store_assets.upload(boundary, report, path, False, lambda: None)
                    self.assertEqual(boundary.writes, [])

    def test_cli_target_version_selects_new_version_for_read_only_inspection(self):
        class InspectionBoundary(AppleBoundary):
            def api(self, method, path, body=None, params=None):
                if method != 'GET':
                    raise AssertionError('检查操作不得写入')
                if path == '/v1/apps':
                    return {'data': [{'id': 'app', 'attributes': {'primaryLocale': 'zh-Hans'}}]}
                if path.endswith('/assetLibrary'):
                    return {'data': {'id': 'library'}}
                if path == '/v1/appAssetLibraryRefData':
                    return {'data': report_fixture()['referenceData']}
                if path.endswith('/appStoreVersions'):
                    return {'data': [
                        {'id': 'published', 'attributes': {'versionString': '1.0.13',
                            'platform': 'IOS', 'appStoreState': 'READY_FOR_DISTRIBUTION'}},
                        {'id': 'draft', 'attributes': {'versionString': '1.0.14',
                            'platform': 'IOS', 'appStoreState': 'PREPARE_FOR_SUBMISSION'}}]}
                if path.startswith('/v1/appStoreVersions/published/'):
                    raise AssertionError('目标检查不得误读已发布版本的本地化或构建')
                if path == '/v1/appStoreVersions/draft/build':
                    return {'data': {'id': 'new-build', 'attributes': {'version': '1'}}}
                return super().api(method, path, body, params)
        with tempfile.TemporaryDirectory() as directory:
            report_path = Path(directory) / 'inspection.json'
            with patch.object(store_assets, 'AppleClient', return_value=InspectionBoundary()), \
                 patch('sys.argv', ['store_assets.py', '--target-version', '1.0.14', '--report', str(report_path)]):
                try:
                    store_assets.main()
                except SystemExit as error:
                    self.fail(f'检查命令必须接受指定目标版本：{error}')
            report = json.loads(report_path.read_text(encoding='utf-8'))
        self.assertEqual(report['requestedVersion'], '1.0.14')
        self.assertEqual([row['attributes']['versionString'] for row in report['versions']], ['1.0.13', '1.0.14'])
        self.assertEqual(report['versions'][1]['build']['id'], 'new-build')
        self.assertEqual(set(report['versions'][1]['placementsByLocale']), set(LOCALES))

    def test_replacement_does_not_temporarily_exceed_apples_ten_screenshot_limit(self):
        class LimitedBoundary(AppleBoundary):
            def api(self, method, path, body=None, params=None):
                if method == 'POST' and path == '/v1/appAssetLibraryPlacements':
                    data = body['data']
                    locale = data['relationships']['appStoreVersionLocalization']['data']['id']
                    group = data['attributes']['placementGroup']
                    if len([p for p in self.placements[locale] if p['attributes']['placementGroup'] == group]) >= 10:
                        raise ValueError('Apple 截图组达到十张上限')
                return super().api(method, path, body, params)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / 'manifest.json'
            path.write_text(json.dumps(manifest_fixture(root)))
            boundary = LimitedBoundary()
            for locale in LOCALES:
                boundary.placements[f'fresh-{locale}'].extend([
                    boundary.placement(f'old-{locale}-{n}', 'APP_SCREENSHOT', 'IPHONE', f'old-image-{n}')
                    for n in range(4)])
            report = report_fixture()
            try:
                store_assets.upload(boundary, report, path, False, lambda: None)
            except ValueError as error:
                self.fail(f'替换旧组时不应先堆叠超过十张：{error}')
            self.assertTrue(report['complete'])
            self.assertEqual(len(report['placements']), 54)

    def test_inspection_reads_three_locale_placements_and_attached_build_without_writing(self):
        class InspectionBoundary(AppleBoundary):
            def api(self, method, path, body=None, params=None):
                if method != 'GET':
                    raise AssertionError('检查操作不得写入')
                if path == '/v1/apps':
                    return {'data': [{'id': 'app', 'attributes': {'primaryLocale': 'zh-Hans'}}]}
                if path.endswith('/assetLibrary'):
                    return {'data': {'id': 'library'}}
                if path == '/v1/appAssetLibraryRefData':
                    return {'data': report_fixture()['referenceData']}
                if path.endswith('/appStoreVersions'):
                    return {'data': report_fixture()['versions']}
                if path == '/v1/appStoreVersions/version/build':
                    return {'data': {'id': 'build-113', 'attributes': {
                        'version': '113', 'processingState': 'VALID'}}}
                return super().api(method, path, body, params)
        report = store_assets.inspect(InspectionBoundary())
        version = report['versions'][0]
        self.assertIn('build', version, '检查报告必须包含当前关联构建，而不是只列出版本')
        self.assertEqual(version['build']['id'], 'build-113')
        self.assertEqual(set(version['placementsByLocale']), set(LOCALES))
        for locale in LOCALES:
            self.assertEqual([p['id'] for p in version['placementsByLocale'][locale]],
                             [f'header-{locale}', f'search-{locale}', f'legacy-{locale}'])

    def test_placement_pagination_retains_server_order_and_rejects_external_page(self):
        class PaginationBoundary:
            def api(self, method, path, body=None, params=None):
                if path.endswith('/placements'):
                    self.first_params = params
                    return {'data': [{'id': 'one'}], 'links': {
                        'next': 'https://api.appstoreconnect.apple.com/v1/page-two'}}
                if path == '/v1/page-two':
                    return {'data': [{'id': 'two'}], 'links': {'next': None}}
                raise AssertionError(path)
        boundary = PaginationBoundary()
        self.assertEqual(store_assets.all_placements(boundary, 'loc', 'APP_SCREENSHOT', 'PHONE'),
                         [{'id': 'one'}, {'id': 'two'}])
        self.assertEqual(boundary.first_params['sort'], 'placementGroupPosition')
        class ExternalPageBoundary:
            def api(self, *args, **kwargs):
                return {'data': [], 'links': {'next': 'https://example.org/v1/page'}}
        with self.assertRaises(ValueError):
            store_assets.all_placements(ExternalPageBoundary(), 'loc')

    def test_upload_places_six_ordered_screenshots_for_each_locale_and_device(self):
        # 错误地复用主语言 ID、按清单文件顺序放置或删除宣传图都会失败。
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            items = manifest_fixture(root)
            path = root / 'manifest.json'
            path.write_text(json.dumps(list(reversed(items))))
            boundary, report = AppleBoundary(), report_fixture()
            store_assets.upload(boundary, report, path, False, lambda: None)
            for locale in LOCALES:
                rows = boundary.placements[f'fresh-{locale}']
                self.assertEqual(len(rows), 20)
                self.assertEqual([row['id'] for row in rows if row['attributes']['placementType'] != 'APP_SCREENSHOT'],
                                 [f'header-{locale}', f'search-{locale}'])
                for device in SIZES:
                    self.assertEqual([row['id'] for row in rows if row['attributes']['placementGroup'] == device.upper()],
                                     [f'p-{locale}-{device}-{order:02d}' for order in range(1, 7)])
            self.assertEqual(len(report['placements']), 54)
            self.assertEqual(set(report['localizedPlacements']), set(LOCALES))
            self.assertEqual(len(boundary.images), 54)
            self.assertTrue(report['complete'])
            first_write_count = len(boundary.writes)
            store_assets.upload(boundary, report, path, False, lambda: None)
            self.assertEqual(len(boundary.images), 54)
            self.assertEqual(len(report['placements']), 54)
            self.assertFalse(any(method == 'DELETE' for method, _, _ in boundary.writes[first_write_count:]))

    def test_invalid_localized_manifest_is_rejected_before_any_apple_write(self):
        # 无验证时少图、重复或语言拼错会引发部分写入；必须在写入之前拒绝。
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original = manifest_fixture(root)
            mutations = {
                'missing': lambda rows: rows.pop(),
                'duplicate-key': lambda rows: rows[0].update(key=rows[1]['key']),
                'duplicate-order': lambda rows: rows[0].update(order=2),
                'wrong-locale': lambda rows: rows[0].update(locale='zh-CN'),
                'wrong-device': lambda rows: rows[0].update(device='watch'),
                'mixed-schema': lambda rows: rows[0].pop('locale'),
                'boolean-order': lambda rows: rows[0].update(order=True),
                'wrong-category': lambda rows: rows[0].update(category='CREATIVE_ASSETS'),
                'duplicate-reference': lambda rows: rows[0].update(referenceName=rows[1]['referenceName']),
                'duplicate-file': lambda rows: rows[0].update(file=rows[1]['file']),
                'duplicate-file-alias': lambda rows: rows[0].update(file='./' + rows[1]['file']),
            }
            for name, mutate in mutations.items():
                with self.subTest(name=name):
                    rows = copy.deepcopy(original)
                    mutate(rows)
                    path = root / 'manifest.json'
                    path.write_text(json.dumps(rows))
                    boundary = AppleBoundary()
                    with self.assertRaises(ValueError):
                        store_assets.upload(boundary, report_fixture(), path, False, lambda: None)
                    self.assertEqual(boundary.writes, [])

    def test_duplicate_server_localization_is_rejected_before_writing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / 'manifest.json'
            path.write_text(json.dumps(manifest_fixture(root)))
            boundary = AppleBoundary()
            boundary.locales.append({'id': 'duplicate', 'attributes': {'locale': 'en-US'}})
            with self.assertRaises(ValueError):
                store_assets.upload(boundary, report_fixture(), path, False, lambda: None)
            self.assertEqual(boundary.writes, [])


if __name__ == '__main__':
    unittest.main()
