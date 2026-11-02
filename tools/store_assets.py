"""通过 Apple 官方素材库接口管理本次商店宣传素材。"""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import struct
import time
import re
from urllib.error import HTTPError
from urllib.parse import urlencode, urlparse
from urllib.request import Request, urlopen


TARGET_LOCALES = ('zh-Hans', 'zh-Hant', 'en-US')
TARGET_DEVICES = ('iphone', 'ipad', 'duo')
SUPPORTED_DEVICES = TARGET_DEVICES + ('iphone-large',)


def commit_payload(asset_id):
    return {'data': {'type': 'appAssetLibraryImages', 'id': asset_id,
                     'attributes': {'uploaded': True}}}


def placement_payload(image_id, locale_id, placement_type, group):
    return {'data': {'type': 'appAssetLibraryPlacements',
                     'attributes': {'placementType': placement_type, 'placementGroup': group},
                     'relationships': {
                         'image': {'data': {'type': 'appAssetLibraryImages', 'id': image_id}},
                         'appStoreVersionLocalization': {'data': {
                             'type': 'appStoreVersionLocalizations', 'id': locale_id}}}}}


def require_editable(version):
    state = version['attributes']['appStoreState']
    if state not in {'PREPARE_FOR_SUBMISSION', 'REJECTED', 'METADATA_REJECTED',
                     'DEVELOPER_REJECTED', 'INVALID_BINARY'}:
        raise ValueError(f'版本不可编辑，未改动产品信息页：{state}')


def resolve_groups(catalog, placement_type, dimensions):
    spec_ids = set()
    for spec in catalog['imageSpecs']:
        size = spec['dimensions']
        if (size['minWidth'] <= dimensions[0] <= size['maxWidth'] and
                size['minHeight'] <= dimensions[1] <= size['maxHeight']):
            spec_ids.add(spec['specId'])
    groups = []
    for kind in catalog['placementTypes']:
        if kind.get('placementTypeId', kind.get('placementType')) != placement_type:
            continue
        for mapping in kind['specMappings']:
            if spec_ids.intersection(mapping['specs']):
                groups.append(mapping.get('placementGroupId', mapping.get('placementGroup')))
    return sorted(set(groups))


def read_manifest(path):
    path = Path(path).resolve()
    items = json.loads(path.read_text(encoding='utf-8'))
    if not isinstance(items, list) or not items or any(not isinstance(item, dict) for item in items):
        raise ValueError('素材清单必须为非空对象数组')
    localized = any(set(item).intersection({'locale', 'device', 'order'}) for item in items)
    seen = {'key': set(), 'file': set(), 'referenceName': set()}
    resolved_files = set()
    for item in items:
        for field in ('key', 'file') + (('referenceName',) if localized else ()):
            value = item.get(field)
            if not isinstance(value, str) or not value.strip() or value in seen[field]:
                raise ValueError(f'素材字段缺失或重复：{field}')
            seen[field].add(value)
        if localized:
            if (item.get('locale') not in TARGET_LOCALES or item.get('device') not in SUPPORTED_DEVICES
                    or type(item.get('order')) is not int or not 1 <= item['order'] <= 6
                    or item.get('category') != 'APP_SCREENSHOTS_AND_PREVIEWS'):
                raise ValueError(f'本地化截图语言、设备、顺序或类别不合法：{item["key"]}')
        target = (path.parent / item['file']).resolve()
        if not target.is_relative_to(path.parent):
            raise ValueError('素材路径超出交付目录')
        if target in resolved_files:
            raise ValueError('素材路径重复指向同一文件')
        resolved_files.add(target)
        if not target.is_file():
            raise ValueError(f'素材文件缺失：{item["key"]}')
        header = target.read_bytes()[:29]
        if len(header) < 29 or header[:8] != b'\x89PNG\r\n\x1a\n' or header[12:16] != b'IHDR':
            raise ValueError('只接受有效 PNG 素材')
        width, height, depth, color = struct.unpack('>IIBB', header[16:26])
        if [width, height] != item['size'] or depth != 8 or color != 2:
            raise ValueError(f'素材尺寸或无透明 RGB 格式不符：{item["key"]}')
    if localized:
        devices = SUPPORTED_DEVICES if any(item['device'] == 'iphone-large' for item in items) else TARGET_DEVICES
        expected = {(locale, device, order) for locale in TARGET_LOCALES
                    for device in devices for order in range(1, 7)}
        actual = {(item['locale'], item['device'], item['order']) for item in items}
        if len(items) != len(expected) or actual != expected:
            raise ValueError('本地化截图必须完整包含三种语言、每种设备各六张；可选大屏 iPhone 规格必须三种语言齐全，且顺序不得重复')
    return items


def backup_report(path):
    path = Path(path)
    if not path.is_file():
        return None
    backup = path.with_name(f'{path.stem}.backup-{time.time_ns()}{path.suffix}')
    with backup.open('xb') as handle:
        handle.write(path.read_bytes())
    return backup


def validate_upload_operations(operations, file_size):
    position = 0
    for operation in sorted(operations, key=lambda row: row['offset']):
        parsed = urlparse(operation['url'])
        if parsed.scheme != 'https' or not (parsed.hostname or '').endswith('.apple.com'):
            raise ValueError('拒绝向非 Apple 上传地址传送素材')
        if operation['offset'] != position or operation['length'] <= 0 or operation['method'] != 'PUT':
            raise ValueError('上传分块不连续或请求方法异常')
        position += operation['length']
    if position != file_size:
        raise ValueError('上传分块总长度不等于素材字节数')


class AppleClient:
    def __init__(self):
        import jwt
        now = int(time.time())
        self.token = jwt.encode(
            {'iss': os.environ['ASC_ISSUER_ID'], 'iat': now - 10,
             'exp': now + 1100, 'aud': 'appstoreconnect-v1'},
            base64.b64decode(os.environ['ASC_KEY_BASE64']), algorithm='ES256',
            headers={'kid': os.environ['ASC_KEY_ID'], 'typ': 'JWT'})

    def api(self, method, path, body=None, params=None):
        allowed_delete = method == 'DELETE' and re.fullmatch(r'/v1/appAssetLibraryPlacements/[A-Za-z0-9-]+', path)
        if method not in {'GET', 'POST', 'PATCH'} and not allowed_delete:
            raise ValueError('本工具不删除素材，仅允许移除草稿页面关联')
        if not path.startswith('/v1/'):
            raise ValueError('只接受 Apple 官方版本化接口路径')
        url = 'https://api.appstoreconnect.apple.com' + path
        if params:
            url += '?' + urlencode(params)
        data = None if body is None else json.dumps(body).encode('utf-8')
        request = Request(url, data=data, method=method,
                          headers={'Authorization': 'Bearer ' + self.token,
                                   'Content-Type': 'application/json'})
        try:
            with urlopen(request, timeout=90) as response:
                raw = response.read()
                return json.loads(raw) if raw else {}
        except HTTPError as error:
            # 不把请求头、签名 URL 或令牌输出到日志。
            try:
                codes = [row.get('code', '') for row in json.loads(error.read()).get('errors', [])]
            except (ValueError, UnicodeError):
                codes = []
            resource_path = path.partition('?')[0]
            raise RuntimeError(f'Apple API {method} {resource_path} HTTP {error.code}: {",".join(codes)}') from None


def inspect(client, target_version='1.0.13'):
    apps = client.api('GET', '/v1/apps', params={'filter[bundleId]': 'com.luolihao.dualcapture'})['data']
    if len(apps) != 1:
        raise ValueError('无法唯一定位同框之外 App，未执行写入')
    app = apps[0]
    app_id = app['id']
    report = {'app': {'id': app_id, 'attributes': app['attributes']}, 'requestedVersion': target_version}
    report['library'] = client.api('GET', f'/v1/apps/{app_id}/assetLibrary')['data']
    report['referenceData'] = client.api('GET', '/v1/appAssetLibraryRefData')['data']
    versions = client.api('GET', f'/v1/apps/{app_id}/appStoreVersions', params={'limit': 50})['data']
    report['versions'] = []
    for version in versions:
        row = {'id': version['id'], 'attributes': version['attributes']}
        if version['attributes'].get('versionString') == target_version:
            row['localizations'] = client.api('GET', f'/v1/appStoreVersions/{version["id"]}/appStoreVersionLocalizations')['data']
            row['placementsByLocale'] = {}
            for locale in row['localizations']:
                name = locale['attributes']['locale']
                if name in TARGET_LOCALES:
                    if name in row['placementsByLocale']:
                        raise ValueError(f'后台本地化语言不唯一：{name}')
                    row['placementsByLocale'][name] = all_placements(client, locale['id'])
            # 只读取已关联构建，不选择构建、不提交审核；无构建时保留 null。
            row['build'] = client.api('GET', f'/v1/appStoreVersions/{version["id"]}/build')['data']
        report['versions'].append(row)
    return report


def all_images(client, library_id):
    images = []
    path = f'/v1/appAssetLibraries/{library_id}/images?limit=200'
    while path:
        response = client.api('GET', path)
        images.extend(response['data'])
        next_url = response.get('links', {}).get('next')
        if next_url:
            if not next_url.startswith('https://api.appstoreconnect.apple.com/v1/'):
                raise ValueError('素材分页地址异常')
            path = next_url.removeprefix('https://api.appstoreconnect.apple.com')
        else:
            path = None
    return images


def all_placements(client, locale_id, placement_type=None, group=None):
    rows = []
    path = f'/v1/appStoreVersionLocalizations/{locale_id}/placements'
    params = {'include': 'image', 'limit': 200, 'sort': 'placementGroupPosition'}
    if placement_type is not None:
        params.update({'filter[placementType]': placement_type, 'filter[placementGroup]': group})
    while path:
        response = client.api('GET', path, params=params)
        rows.extend(response['data'])
        next_url = response.get('links', {}).get('next')
        if next_url and not next_url.startswith('https://api.appstoreconnect.apple.com/v1/'):
            raise ValueError('产品页关联分页地址异常')
        path = next_url.removeprefix('https://api.appstoreconnect.apple.com') if next_url else None
        params = None
    return rows


def upload_image(client, library_id, item, root, existing):
    content = (root / item['file']).read_bytes()
    digest = hashlib.sha256(content).hexdigest()
    name = item['referenceName'] + '-' + digest[:8]
    matches = [row for row in existing if row['attributes'].get('referenceName') == name]
    if len(matches) > 1:
        raise ValueError('同名同内容素材不唯一，停止以避免重复上传')
    if matches:
        asset = client.api('GET', '/v1/appAssetLibraryImages/' + matches[0]['id'])['data']
    else:
        asset = client.api('POST', '/v1/appAssetLibraryImages', {'data': {
            'type': 'appAssetLibraryImages', 'attributes': {
                'fileName': Path(item['file']).name, 'fileSize': len(content),
                'category': item['category'], 'referenceName': name},
            'relationships': {'assetLibrary': {'data': {'type': 'appAssetLibraries', 'id': library_id}}}}})['data']
    asset_id = asset['id']
    state = asset['attributes']['state']
    if state == 'FAILED':
        raise ValueError(f'既有素材处理失败，保留原记录供检查：{item["key"]}')
    if state == 'AWAITING_UPLOAD':
        operations = asset['attributes']['uploadOperations']
        validate_upload_operations(operations, len(content))
        for operation in operations:
            headers = {entry['name']: entry['value'] for entry in operation['requestHeaders']}
            offset, length = operation['offset'], operation['length']
            # 独立请求只使用 Apple 返回的上传头，不附带 API JWT。
            request = Request(operation['url'], data=content[offset:offset + length],
                              headers=headers, method=operation['method'])
            try:
                with urlopen(request, timeout=120) as response:
                    response.read()
            except Exception:
                raise RuntimeError(f'素材分块传输失败：{item["key"]}；未输出签名地址') from None
        asset = client.api('PATCH', '/v1/appAssetLibraryImages/' + asset_id, commit_payload(asset_id))['data']
    return {'key': item['key'], 'id': asset_id, 'sha256': digest,
            'state': asset['attributes']['state'], 'specId': asset['attributes'].get('specId')}


def prepare_draft(client, report, create_draft, target_locales=None):
    target_version = report.get('requestedVersion', '1.0.13')
    matches = [v for v in report['versions'] if v['attributes'].get('versionString') == target_version
               and v['attributes'].get('platform') == 'IOS']
    if len(matches) > 1:
        raise ValueError(f'{target_version} 产品版本不唯一')
    if not matches:
        if not create_draft:
            raise ValueError(f'没有 {target_version} 草稿；素材已保留在素材库')
        version = client.api('POST', '/v1/appStoreVersions', {'data': {
            'type': 'appStoreVersions', 'attributes': {'platform': 'IOS', 'versionString': target_version},
            'relationships': {'app': {'data': {'type': 'apps', 'id': report['app']['id']}}}}})['data']
    else:
        version = client.api('GET', '/v1/appStoreVersions/' + matches[0]['id'])['data']
    require_editable(version)
    if (version['attributes'].get('versionString', target_version) != target_version
            or version['attributes'].get('platform', 'IOS') != 'IOS'):
        raise ValueError('目标版本复查不一致，未上传素材')
    locales = client.api('GET', f'/v1/appStoreVersions/{version["id"]}/appStoreVersionLocalizations')['data']
    primary = report['app']['attributes']['primaryLocale']
    if target_locales is None and primary != 'zh-Hans':
        raise ValueError('主语言不是简体中文，未自动替换其他语言素材')
    wanted = target_locales or (primary,)
    selected = {}
    for locale in wanted:
        rows = [row for row in locales if row['attributes']['locale'] == locale]
        if len(rows) > 1:
            raise ValueError(f'后台本地化语言不唯一，未上传素材：{locale}')
        if rows:
            selected[locale] = rows[0]
    if len({row['id'] for row in selected.values()}) != len(selected):
        raise ValueError('后台本地化 ID 重复，未上传素材')
    for locale in wanted:
        if locale not in selected:
            selected[locale] = client.api('POST', '/v1/appStoreVersionLocalizations', {'data': {
                'type': 'appStoreVersionLocalizations', 'attributes': {'locale': locale},
                'relationships': {'appStoreVersion': {'data': {'type': 'appStoreVersions', 'id': version['id']}}}}})['data']
    return version, selected if target_locales is not None else selected[primary]


def upload(client, report, manifest_path, create_draft, checkpoint):
    manifest_path = Path(manifest_path).resolve()
    items = read_manifest(manifest_path)
    target_version = report.get('requestedVersion', '1.0.13')
    localized = 'locale' in items[0]
    report['complete'] = False
    if localized:
        devices = SUPPORTED_DEVICES if any(item['device'] == 'iphone-large' for item in items) else TARGET_DEVICES
        items.sort(key=lambda item: (TARGET_LOCALES.index(item['locale']),
                                    devices.index(item['device']), item['order']))
    catalog = report['referenceData'][0]['attributes']
    for item in items:
        placement_type = ('PRODUCT_PAGE_HEADER_ASSET' if item['key'] == 'creative-header' else
                          'APP_STORE_SEARCH_RESULTS_ASSET' if item['key'] == 'creative-search' else 'APP_SCREENSHOT')
        groups = resolve_groups(catalog, placement_type, item['size'])
        if len(groups) != 1:
            raise ValueError(f'无法唯一匹配官方设备规格：{item["key"]} {groups}')
        item['placementType'], item['placementGroup'] = placement_type, groups[0]
    if localized:
        device_groups = {device: {item['placementGroup'] for item in items if item['device'] == device}
                         for device in devices}
        if any(len(groups) != 1 for groups in device_groups.values()) or len(set.union(*device_groups.values())) != len(devices):
            raise ValueError('每种设备规格必须分别匹配唯一官方截图分组，未写入素材')
        version, locales = prepare_draft(client, report, create_draft, TARGET_LOCALES)
        report['targetVersion'] = {'id': version['id'], 'version': target_version,
            'localizations': {name: row['id'] for name, row in locales.items()}}
    else:
        version, locale = prepare_draft(client, report, create_draft)
        locales = {locale['attributes']['locale']: locale}
        report['targetVersion'] = {'id': version['id'], 'version': target_version,
                                  'locale': locale['attributes']['locale'], 'localeId': locale['id']}
    checkpoint()
    print(f'产品页草稿已就绪：{target_version}，语言 {", ".join(locales)}。', flush=True)
    report['uploads'] = []
    existing = all_images(client, report['library']['id'])
    for item in items:
        row = upload_image(client, report['library']['id'], item, manifest_path.parent, existing)
        report['uploads'].append(row)
        checkpoint()
        print(item['key'], row['state'], flush=True)
    report['processingPending'] = []
    for row in report['uploads']:
        asset = client.api('GET', '/v1/appAssetLibraryImages/' + row['id'])['data']['attributes']
        row.update(state=asset['state'], specId=asset.get('specId'))
        if asset['state'] == 'FAILED':
            row['stateDetails'] = asset.get('stateDetails')
            checkpoint()
            raise ValueError(f'Apple 素材处理失败：{row["key"]}')
        if asset['state'] in {'AWAITING_UPLOAD', 'UPLOAD_COMPLETE'}:
            report['processingPending'].append(row['key'])
    # Apple 支持在素材处理期间建立 ASSET_PROCESSING 关联；无需轮询阻塞草稿页。
    checkpoint()
    previous = {name: all_placements(client, row['id']) for name, row in locales.items()}
    report['previousPlacementsByLocale'] = json.loads(json.dumps(previous))
    report['previousPlacements'] = [row for rows in report['previousPlacementsByLocale'].values() for row in rows]
    report['placements'] = []
    report['localizedPlacements'] = {name: [] for name in locales}
    checkpoint()
    for name, locale in locales.items():
        pairs = [(item, asset) for item, asset in zip(items, report['uploads'])
                 if not localized or item['locale'] == name]
        groups = sorted({(item['placementType'], item['placementGroup']) for item, _ in pairs})
        for placement_type, group in groups:
            related = [p for p in previous[name] if p['attributes']['placementType'] == placement_type
                       and p['attributes']['placementGroup'] == group]
            wanted = [(item, asset) for item, asset in pairs
                      if item['placementType'] == placement_type and item['placementGroup'] == group]
            desired_images = {asset['id'] for _, asset in wanted}
            existing_images = set()
            kept = []
            # 先移除旧页面关联，避免旧五张加新六张短暂超过十张上限。
            # 同一新素材只保留一个关联；底层素材文件与其他分组均不删除。
            for prior in related:
                image_id = (prior.get('relationships', {}).get('image', {}).get('data') or {}).get('id')
                if image_id in desired_images and image_id not in existing_images:
                    kept.append(prior)
                    existing_images.add(image_id)
                else:
                    client.api('DELETE', '/v1/appAssetLibraryPlacements/' + prior['id'])
            related = kept
            retained = set()
            ordered = []
            for item, asset in wanted:
                already = [p for p in related if p['id'] not in retained
                           and (p.get('relationships', {}).get('image', {}).get('data') or {}).get('id') == asset['id']]
                if already:
                    placed = already[0]
                else:
                    placed = client.api('POST', '/v1/appAssetLibraryPlacements', placement_payload(
                        asset['id'], locale['id'], placement_type, group))['data']
                retained.add(placed['id'])
                row = {'key': item['key'], 'id': placed['id'], 'locale': name, 'localeId': locale['id'],
                       'state': placed['attributes']['state'], 'group': group,
                       'type': placement_type, 'imageId': asset['id']}
                if localized:
                    row.update(device=item['device'], order=item['order'])
                ordered.append(row)
                report['placements'].append(row)
                report['localizedPlacements'][name].append(row)
                checkpoint()
            if placement_type == 'APP_SCREENSHOT':
                client.api('POST', '/v1/appAssetLibraryPlacementOrderingRequests', {'data': {
                    'type': 'appAssetLibraryPlacementOrderingRequests', 'attributes': {'placementGroup': group},
                    'relationships': {'orderedPlacements': {'data': [
                        {'type': 'appAssetLibraryPlacements', 'id': p['id']} for p in ordered]},
                        'appStoreVersionLocalization': {'data': {
                            'type': 'appStoreVersionLocalizations', 'id': locale['id']}}}}})
            actual = all_placements(client, locale['id'], placement_type, group)
            if [p['id'] for p in actual] != [p['id'] for p in ordered]:
                raise ValueError(f'产品页关联数量或顺序不符，不能报告上传完成：{name} {group}')
    report['complete'] = True
    checkpoint()
    print(f'{len(items)} 张素材已上传并关联到 {target_version} 的 {len(locales)} 种语言草稿；'
          f'{len(report["processingPending"])} 张仍在 Apple 处理中；未提交审核、未发布。')


def update_metadata(client, report, copy_path, checkpoint):
    content = json.loads(Path(copy_path).read_text(encoding='utf-8'))
    target_version = report.get('requestedVersion', '1.0.13')
    if set(content) != {'version', 'localizations'} or content['version'] != target_version:
        raise ValueError(f'仅允许更新本次 {target_version} 本地化文案')
    desired = content['localizations']
    if set(desired) != {'zh-Hans', 'zh-Hant', 'en-US'}:
        raise ValueError('本次文案必须完整包含简体、繁体和英文')
    for locale, fields in desired.items():
        if set(fields) != {'description', 'whatsNew'}:
            raise ValueError(f'不允许修改描述、更新说明之外的字段：{locale}')
        for value in fields.values():
            if not isinstance(value, str) or not value.strip() or len(value) > 4000:
                raise ValueError(f'文案为空或超过 4000 字符：{locale}')
    versions = [v for v in report['versions'] if v['attributes'].get('versionString') == content['version']
                and v['attributes'].get('platform') == 'IOS']
    if len(versions) != 1:
        raise ValueError(f'没有唯一的 {target_version} iOS 草稿版本，未写入文案')
    version = client.api('GET', '/v1/appStoreVersions/' + versions[0]['id'])['data']
    require_editable(version)
    if version['attributes'].get('versionString') != content['version']:
        raise ValueError('版本复查不一致，未写入文案')
    rows = client.api('GET', f'/v1/appStoreVersions/{version["id"]}/appStoreVersionLocalizations')['data']
    localized = {row['attributes']['locale']: row for row in rows}
    if set(localized) != set(desired) or len(rows) != len(desired):
        raise ValueError('后台本地化语言与本次文案不一致，未写入任何语言')
    report['metadataVersion'] = {'id': version['id'], 'version': content['version']}
    report['metadataPrevious'] = {locale: {'id': row['id'], 'fields': {
        field: row['attributes'].get(field) for field in ('description', 'whatsNew')}}
        for locale, row in localized.items()}
    report['metadataVerified'] = {}
    checkpoint()
    for locale, fields in desired.items():
        locale_id = localized[locale]['id']
        client.api('PATCH', '/v1/appStoreVersionLocalizations/' + locale_id, {'data': {
            'type': 'appStoreVersionLocalizations', 'id': locale_id, 'attributes': fields}})
        actual = client.api('GET', '/v1/appStoreVersionLocalizations/' + locale_id)['data']['attributes']
        if any(actual.get(field) != value for field, value in fields.items()):
            raise ValueError(f'写入后重新读取的文案不一致：{locale}')
        report['metadataVerified'][locale] = {'id': locale_id, 'description': actual['description'],
                                             'whatsNew': actual['whatsNew']}
        checkpoint()
        print(f'{locale}：描述和此版本新增内容已保存并重新读取核对。', flush=True)
    report['metadataComplete'] = True
    checkpoint()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--report', required=True)
    parser.add_argument('--target-version', default='1.0.13', help='目标 iOS 商店版本号，默认 1.0.13')
    action = parser.add_mutually_exclusive_group()
    action.add_argument('--manifest')
    action.add_argument('--metadata')
    parser.add_argument('--create-draft', action='store_true')
    args = parser.parse_args()
    destination = Path(args.report)
    destination.parent.mkdir(parents=True, exist_ok=True)
    backup_report(destination)
    report = {}
    def checkpoint():
        destination.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    try:
        client = AppleClient()
        report = inspect(client, args.target_version)
        checkpoint()
        if args.manifest:
            upload(client, report, args.manifest, args.create_draft, checkpoint)
            return
        if args.metadata:
            update_metadata(client, report, args.metadata, checkpoint)
            return
        print('素材库、参考规格和版本状态读取成功；本步骤未写入 Apple 后台。')
    except Exception as error:
        report['error'] = str(error)
        checkpoint()
        raise SystemExit(str(error)) from None


if __name__ == '__main__':
    main()
