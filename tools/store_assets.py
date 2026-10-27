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
    for item in items:
        target = (path.parent / item['file']).resolve()
        if not target.is_relative_to(path.parent):
            raise ValueError('素材路径超出交付目录')
        if not target.is_file():
            raise ValueError(f'素材文件缺失：{item["key"]}')
        header = target.read_bytes()[:29]
        if len(header) < 29 or header[:8] != b'\x89PNG\r\n\x1a\n' or header[12:16] != b'IHDR':
            raise ValueError('只接受有效 PNG 素材')
        width, height, depth, color = struct.unpack('>IIBB', header[16:26])
        if [width, height] != item['size'] or depth != 8 or color != 2:
            raise ValueError(f'素材尺寸或无透明 RGB 格式不符：{item["key"]}')
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


def inspect(client):
    apps = client.api('GET', '/v1/apps', params={'filter[bundleId]': 'com.luolihao.dualcapture'})['data']
    if len(apps) != 1:
        raise ValueError('无法唯一定位同框之外 App，未执行写入')
    app = apps[0]
    app_id = app['id']
    report = {'app': {'id': app_id, 'attributes': app['attributes']}}
    report['library'] = client.api('GET', f'/v1/apps/{app_id}/assetLibrary')['data']
    report['referenceData'] = client.api('GET', '/v1/appAssetLibraryRefData')['data']
    versions = client.api('GET', f'/v1/apps/{app_id}/appStoreVersions', params={'limit': 50})['data']
    report['versions'] = []
    for version in versions:
        row = {'id': version['id'], 'attributes': version['attributes']}
        if version['attributes'].get('versionString') == '1.0.13':
            row['localizations'] = client.api('GET', f'/v1/appStoreVersions/{version["id"]}/appStoreVersionLocalizations')['data']
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


def prepare_draft(client, report, create_draft):
    matches = [v for v in report['versions'] if v['attributes'].get('versionString') == '1.0.13'
               and v['attributes'].get('platform') == 'IOS']
    if len(matches) > 1:
        raise ValueError('1.0.13 产品版本不唯一')
    if not matches:
        if not create_draft:
            raise ValueError('没有 1.0.13 草稿；素材已保留在素材库')
        version = client.api('POST', '/v1/appStoreVersions', {'data': {
            'type': 'appStoreVersions', 'attributes': {'platform': 'IOS', 'versionString': '1.0.13'},
            'relationships': {'app': {'data': {'type': 'apps', 'id': report['app']['id']}}}}})['data']
    else:
        version = client.api('GET', '/v1/appStoreVersions/' + matches[0]['id'])['data']
    require_editable(version)
    locales = client.api('GET', f'/v1/appStoreVersions/{version["id"]}/appStoreVersionLocalizations')['data']
    primary = report['app']['attributes']['primaryLocale']
    if primary != 'zh-Hans':
        raise ValueError('主语言不是简体中文，未自动替换其他语言素材')
    selected = [row for row in locales if row['attributes']['locale'] == primary]
    if not selected:
        selected = [client.api('POST', '/v1/appStoreVersionLocalizations', {'data': {
            'type': 'appStoreVersionLocalizations', 'attributes': {'locale': primary},
            'relationships': {'appStoreVersion': {'data': {'type': 'appStoreVersions', 'id': version['id']}}}}})['data']]
    return version, selected[0]


def upload(client, report, manifest_path, create_draft, checkpoint):
    manifest_path = Path(manifest_path).resolve()
    items = read_manifest(manifest_path)
    catalog = report['referenceData'][0]['attributes']
    for item in items:
        placement_type = ('PRODUCT_PAGE_HEADER_ASSET' if item['key'] == 'creative-header' else
                          'APP_STORE_SEARCH_RESULTS_ASSET' if item['key'] == 'creative-search' else 'APP_SCREENSHOT')
        groups = resolve_groups(catalog, placement_type, item['size'])
        if len(groups) != 1:
            raise ValueError(f'无法唯一匹配官方设备规格：{item["key"]} {groups}')
        item['placementType'], item['placementGroup'] = placement_type, groups[0]
    version, locale = prepare_draft(client, report, create_draft)
    report['targetVersion'] = {'id': version['id'], 'version': '1.0.13', 'locale': locale['attributes']['locale'], 'localeId': locale['id']}
    checkpoint()
    print(f'产品页草稿已就绪：1.0.13，语言 {locale["attributes"]["locale"]}。', flush=True)
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
    old = client.api('GET', f'/v1/appStoreVersionLocalizations/{locale["id"]}/placements',
                     params={'include': 'image', 'limit': 200, 'sort': 'placementGroupPosition'})['data']
    report['previousPlacements'] = json.loads(json.dumps(old))
    report['placements'] = []
    new_image_ids = {row['id'] for row in report['uploads']}
    new_placement_ids = set()
    checkpoint()
    for item, asset in zip(items, report['uploads']):
        related = [p for p in old if p['attributes']['placementType'] == item['placementType']
                   and p['attributes']['placementGroup'] == item['placementGroup']]
        for prior in related:
            prior_image = (prior.get('relationships', {}).get('image', {}).get('data') or {}).get('id')
            if prior['id'] in new_placement_ids or prior_image in new_image_ids:
                continue
            client.api('DELETE', '/v1/appAssetLibraryPlacements/' + prior['id'])
            old.remove(prior)
        already = [p for p in related if (p.get('relationships', {}).get('image', {}).get('data') or {}).get('id') == asset['id']]
        if already:
            placed = already[0]
        else:
            # 旧素材文件不删除；本轮新增关联用 ID 保护，不依赖 POST 响应展开关系。
            placed = client.api('POST', '/v1/appAssetLibraryPlacements', placement_payload(
                asset['id'], locale['id'], item['placementType'], item['placementGroup']))['data']
            old.append(placed)
        new_placement_ids.add(placed['id'])
        report['placements'].append({'key': item['key'], 'id': placed['id'],
                                     'state': placed['attributes']['state'], 'group': item['placementGroup'],
                                     'type': item['placementType'], 'imageId': asset['id']})
        checkpoint()
    groups = sorted({p['group'] for p in report['placements'] if p['type'] == 'APP_SCREENSHOT'})
    for group in groups:
        ordered = [p for p in report['placements'] if p['group'] == group and p['type'] == 'APP_SCREENSHOT']
        client.api('POST', '/v1/appAssetLibraryPlacementOrderingRequests', {'data': {
            'type': 'appAssetLibraryPlacementOrderingRequests', 'attributes': {'placementGroup': group},
            'relationships': {'orderedPlacements': {'data': [{'type': 'appAssetLibraryPlacements', 'id': p['id']} for p in ordered]},
                              'appStoreVersionLocalization': {'data': {'type': 'appStoreVersionLocalizations', 'id': locale['id']}}}}})
    for placement_type, group in sorted({(p['type'], p['group']) for p in report['placements']}):
        actual = client.api('GET', f'/v1/appStoreVersionLocalizations/{locale["id"]}/placements',
                            params={'filter[placementType]': placement_type, 'filter[placementGroup]': group,
                                    'sort': 'placementGroupPosition', 'limit': 200})['data']
        expected = [p['id'] for p in report['placements'] if p['type'] == placement_type and p['group'] == group]
        if [p['id'] for p in actual] != expected:
            raise ValueError('产品页关联数量或顺序不符，不能报告上传完成')
    report['complete'] = True
    checkpoint()
    print(f'{len(items)} 张素材已上传并关联到 1.0.13 简体中文草稿；'
          f'{len(report["processingPending"])} 张仍在 Apple 处理中；未提交审核、未发布。')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--report', required=True)
    parser.add_argument('--manifest')
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
        report = inspect(client)
        checkpoint()
        if args.manifest:
            upload(client, report, args.manifest, args.create_draft, checkpoint)
            return
        print('素材库、参考规格和版本状态读取成功；本步骤未写入 Apple 后台。')
    except Exception as error:
        report['error'] = str(error)
        checkpoint()
        raise SystemExit(str(error)) from None


if __name__ == '__main__':
    main()
